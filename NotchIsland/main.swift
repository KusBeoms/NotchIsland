import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps

// NotchIsland — a Dynamic-Island-style overlay for the MacBook notch.
//
// Usage: NotchIsland [--threshold N] [--force-open] [--demo-alert TEXT] [--demo-timer] [--demo-media]
//   --threshold N       dark "touch" when ambient light (raw ALS units) drops below N (default 50; covering the sensor reads ~1)
//   --force-open        keep the island expanded (testing)
//   --demo-alert TEXT   show TEXT as an alert at launch (testing)
//   --demo-timer        start the stopwatch at launch (testing)
//   --demo-media        show a fake playing track (testing)
//
// Behaviour
//   * Hover the notch      -> swells sideways a little
//   * Press the notch      -> reacts at once; with nothing running it pops out and straight back in
//   * Something running (alert / media / stopwatch) -> hold ~0.25s to pop open; it stays open until you click elsewhere
//   * Collapsed + running  -> compact "wings": album art + equalizer, or timer icon + time
//   * Expanded media       -> art, title/artist, progress, previous / play-pause / next
//   * Expanded stopwatch   -> pause + cancel, big orange time
//   * Ambient light dark   -> a touch-like pop
//   * Battery events       -> alert (plug in / unplug / 20% / 10% / full)

var threshold = 50.0
var forceOpen = false
var demoAlert: String? = nil
var demoTimer = false
var demoMedia = false
var demoCharging = false
var demoAirpods = false
var demoVolume = false
var demoActsN: Int? = nil           // --demo-acts N: show N fake live activities (1...5)
var demoKinds = Set<ActKind>()
var demoPick: [String]? = nil          // --demo-kinds media,timer,charging,airpods,lowBattery (any subset)
var demoBrightness = false
var argIt = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIt.next() {
    switch a {
    case "--threshold": if let v = argIt.next(), let d = Double(v) { threshold = d }
    case "--force-open": forceOpen = true
    case "--demo-alert": demoAlert = argIt.next()
    case "--demo-timer": demoTimer = true
    case "--demo-media": demoMedia = true
    case "--demo-charging": demoCharging = true
    case "--demo-airpods": demoAirpods = true
    case "--demo-volume": demoVolume = true
    case "--demo-kinds": demoPick = argIt.next()?.split(separator: ",").map(String.init); demoActsN = demoActsN ?? 0
    case "--demo-acts": if let v = argIt.next(), let n = Int(v) { demoActsN = min(max(n, 0), 5) }
    case "--demo-brightness": demoBrightness = true
    default: break
    }
}

let accent = NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)   // timer orange
let bannerGreen = NSColor(red: 0.35, green: 0.9, blue: 0.5, alpha: 1)
let bannerRed = NSColor(red: 1.0, green: 0.35, blue: 0.3, alpha: 1)

// MARK: - Staying put while Spaces slide

/// Moves a window into a private top-most "overlay" Space that is shown on top of every desktop. Windows there do not
/// take part in Space transitions (three-finger swipe, Ctrl+arrow), so the island stays at the notch instead of
/// sliding in with the new desktop. Uses private SkyLight calls; if they are missing the window is left as it is.
enum Overlay {
    typealias Conn = @convention(c) () -> Int32
    typealias Create = @convention(c) (Int32, Int32, UnsafeRawPointer?) -> UInt64
    typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    typealias Show = @convention(c) (Int32, CFArray) -> Int32
    typealias Add = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    static var space: UInt64 = 0
    static var ok = false

    static func sym<T>(_ name: String, _ t: T.Type) -> T? {
        guard let h = lib, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: t)
    }

    static func attach(_ w: NSWindow) {
        guard w.windowNumber > 0,
              let conn = sym("SLSMainConnectionID", Conn.self), let create = sym("SLSSpaceCreate", Create.self),
              let level = sym("SLSSpaceSetAbsoluteLevel", SetLevel.self), let show = sym("SLSShowSpaces", Show.self),
              let add = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", Add.self) else { return }
        let cid = conn()
        if space == 0 {
            space = create(cid, 1, nil)
            guard space != 0 else { return }
            _ = level(cid, space, 2_147_483_647)
            _ = show(cid, [NSNumber(value: space)] as CFArray)
            ok = true
        }
        _ = add(cid, space, [NSNumber(value: w.windowNumber)] as CFArray, 7)
    }
}
func makeSticky(_ w: NSWindow) { Overlay.attach(w) }

// MARK: - Haptics

/// Force Touch trackpad tap. macOS only plays it while a finger is on the trackpad
/// (hovering with the pointer, clicking, touching) — otherwise the call is a silent no-op.
func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
}

// MARK: - Battery

struct Battery { var level: Int; var plugged: Bool; var charging: Bool }

/// Full = plugged in and no longer charging near the top. Also covers macOS charge limits (80–95%).
func isFull(_ b: Battery) -> Bool { b.plugged && ((b.level >= 100) || (!b.charging && b.level >= 80)) }

func readBattery() -> Battery? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
              (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
              let cur = d[kIOPSCurrentCapacityKey] as? Int,
              let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0 else { continue }
        let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        return Battery(level: cur * 100 / mx, plugged: plugged, charging: charging)
    }
    return nil
}

// MARK: - Now playing (system-wide: Music, Spotify, browsers, Podcasts ...)
//
// Since macOS 15.4 only Apple-signed processes may talk to MediaRemote, so an app cannot call it directly.
// /usr/bin/osascript is Apple-signed, so the lookup and the transport commands run inside it (JXA).

struct Media {
    var title: String
    var artist: String
    var playing: Bool
    var duration: TimeInterval
    var elapsed: TimeInterval      // position at `readAt`
    var readAt: Date
    var storeID: String
    var bundleID: String = ""          // the app that is playing (a browser for web video)
    var elapsedNow: TimeInterval {
        let e = elapsed + (playing ? Date().timeIntervalSince(readAt) : 0)
        return duration > 0 ? min(e, duration) : e
    }
}

private let nowPlayingScript = """
ObjC.import("Foundation");
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
var out = "NONE";
var req = $.NSClassFromString("MRNowPlayingRequest");
if (req) {
  var item = req.localNowPlayingItem;
  if (item && !item.isNil()) {
    var info = item.nowPlayingInfo;
    var g = function (k) { try { return ObjC.unwrap(info.objectForKey(k)); } catch (e) { return null; } };
    var title = g("kMRMediaRemoteNowPlayingInfoTitle");
    var appBundle = "";
    try {
      var client = req.localNowPlayingPlayerPath.client;
      appBundle = ObjC.unwrap(client.parentApplicationBundleIdentifier) || ObjC.unwrap(client.bundleIdentifier) || "";
    } catch (e) {}
    if (title) {
      var pos = null;
      try { pos = item.metadata.calculatedPlaybackPosition; } catch (e) {}
      out = JSON.stringify({
        title: title,
        artist: g("kMRMediaRemoteNowPlayingInfoArtist") || "",
        rate: g("kMRMediaRemoteNowPlayingInfoPlaybackRate") || 0,
        duration: g("kMRMediaRemoteNowPlayingInfoDuration") || 0,
        elapsed: (pos !== null && pos !== undefined) ? pos : (g("kMRMediaRemoteNowPlayingInfoElapsedTime") || 0),
        id: String(g("kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier") || ""),
        app: appBundle
      });
    }
  }
}
out;
"""

/// Runs a tool with a watchdog and returns its stdout.
func runTool(_ path: String, _ args: [String], timeout: TimeInterval = 4) -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return Data() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }   // watchdog
    let data = out.fileHandleForReading.readDataToEndOfFile()   // read first, then wait (avoids pipe-full deadlock)
    p.waitUntilExit()
    return data
}

/// Runs osascript (JXA) and returns trimmed stdout.
func runJXA(_ script: String) -> String {
    String(data: runTool("/usr/bin/osascript", ["-l", "JavaScript", "-e", script]), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

enum PollResult { case failed, nothing, media(Media) }

func queryNowPlaying() -> PollResult {
    let s = runJXA(nowPlayingScript)
    if s.isEmpty { return .failed }                  // timed out / crashed: say nothing about the state
    if s == "NONE" { return .nothing }
    guard let d = s.data(using: .utf8),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let title = j["title"] as? String else { return .failed }
    func num(_ k: String) -> Double { (j[k] as? NSNumber)?.doubleValue ?? 0 }
    return .media(Media(title: title, artist: (j["artist"] as? String) ?? "", playing: num("rate") > 0,
                        duration: num("duration"), elapsed: num("elapsed"), readAt: Date(), storeID: (j["id"] as? String) ?? "",
                        bundleID: (j["app"] as? String) ?? ""))
}

/// MediaRemote command ids: 2 toggle play/pause, 4 next, 5 previous.
func sendMediaCommand(_ cmd: Int) {
    DispatchQueue.global(qos: .userInitiated).async {
        _ = runJXA("""
        ObjC.import("Foundation");
        $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
        $.NSClassFromString("MRNowPlayingController").localRouteController.sendCommandOptionsCompletion(\(cmd), $(), null);
        delay(0.2);
        "";
        """)
    }
}

// MARK: - AirPods (connected Apple headphones + battery, from the Bluetooth system report)

struct AirPodsInfo { var name: String; var symbol: String; var level: Int? }

func queryAirPods() -> [AirPodsInfo] {
    let data = runTool("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"], timeout: 10)
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let first = (j["SPBluetoothDataType"] as? [[String: Any]])?.first,
          let connected = first["device_connected"] as? [[String: Any]] else { return [] }
    var out: [AirPodsInfo] = []
    for entry in connected {
        for (name, v) in entry {
            guard let info = v as? [String: Any],
                  (info["device_vendorID"] as? String)?.lowercased() == "0x004c",       // Apple
                  (info["device_minorType"] as? String) == "Headphones" else { continue }
            let pid = (info["device_productID"] as? String)?.lowercased() ?? ""
            let levels = ["device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelMain"].compactMap {
                (info[$0] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
            }
            let symbol = pid == "0x200a" ? "airpodsmax"
                : ["0x200e", "0x2014", "0x2024", "0x2027"].contains(pid) ? "airpodspro" : "airpods"
            out.append(AirPodsInfo(name: name, symbol: symbol, level: levels.min()))   // like iPhone: the lower bud
        }
    }
    return out
}

enum BannerKind {
    case battery(title: String, level: Int, color: NSColor)
    case airpods(symbol: String, level: Int?)
}

// MARK: - Volume / brightness (read, set) and the media keys that drive them

enum SystemLevels {
    private static func outputDevice() -> AudioObjectID? {
        var dev = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr, dev != 0 else { return nil }
        return dev
    }
    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static func settable(_ d: AudioObjectID, _ a: inout AudioObjectPropertyAddress) -> Bool {
        var ok: DarwinBoolean = false
        return AudioObjectHasProperty(d, &a) && AudioObjectIsPropertySettable(d, &a, &ok) == noErr && ok.boolValue
    }

    static var volumeControllable: Bool {
        guard let d = outputDevice() else { return false }
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        return settable(d, &a)
    }
    static func volume() -> Float? {
        guard let d = outputDevice() else { return nil }
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(d, &a) else { return nil }
        var v: Float32 = 0; var sz = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr ? v : nil
    }
    @discardableResult static func setVolume(_ v: Float) -> Bool {
        guard let d = outputDevice() else { return false }
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard settable(d, &a) else { return false }
        var x = Float32(min(max(v, 0), 1))
        return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &x) == noErr
    }
    static func muted() -> Bool? {
        guard let d = outputDevice() else { return nil }
        var a = addr(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(d, &a) else { return nil }
        var v: UInt32 = 0; var sz = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr ? v != 0 : nil
    }
    @discardableResult static func setMuted(_ m: Bool) -> Bool {
        guard let d = outputDevice() else { return false }
        var a = addr(kAudioDevicePropertyMute)
        guard settable(d, &a) else { return false }
        var x: UInt32 = m ? 1 : 0
        return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &x) == noErr
    }

    // Brightness goes through the private DisplayServices framework (the same one System Settings uses).
    private static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private typealias GetB = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetB = @convention(c) (UInt32, Float) -> Int32

    static var builtinDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }
    static func brightness() -> Float? {
        guard let h = ds, let sym = dlsym(h, "DisplayServicesGetBrightness"), let id = builtinDisplay else { return nil }
        var b: Float = 0
        return unsafeBitCast(sym, to: GetB.self)(id, &b) == 0 ? b : nil
    }
    static var brightnessControllable: Bool {
        guard let h = ds else { return false }
        return dlsym(h, "DisplayServicesSetBrightness") != nil && brightness() != nil
    }
    @discardableResult static func setBrightness(_ v: Float) -> Bool {
        guard let h = ds, let sym = dlsym(h, "DisplayServicesSetBrightness"), let id = builtinDisplay else { return false }
        return unsafeBitCast(sym, to: SetB.self)(id, min(max(v, 0), 1)) == 0
    }
}

/// Swallows the volume / brightness / mute keys (so the system HUD never fires) and hands them to `onKey`.
/// Needs the Accessibility permission; `install()` simply returns false until it is granted.
final class MediaKeyTap {
    var onKey: ((_ code: Int, _ down: Bool, _ fine: Bool) -> Bool)?   // true = handled (swallow the event)
    private(set) var tap: CFMachPort?
    var isActive: Bool { tap != nil }

    @discardableResult func install() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1) << 14                      // NX_SYSDEFINED: media / function keys
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {     // the system pauses slow taps: turn it back on
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let d1 = ns.data1
        let code = (d1 & 0xFFFF0000) >> 16
        let down = ((d1 & 0x0000FF00) >> 8) == 0xA          // 0xA = key down (also for auto-repeat), 0xB = key up
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)   // Shift+Option = quarter steps
        return (onKey?(code, down, fine) ?? false) ? nil : Unmanaged.passUnretained(event)
    }
}

// MARK: - Artwork (album art via Apple's public iTunes lookup, keyed by the track's store id)

func averageColor(_ img: NSImage) -> NSColor {
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return accent }
    var px = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return accent }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return NSColor(hue: h, saturation: max(s, 0.45), brightness: max(b, 0.9), alpha: 1)   // keep it readable on black
}

func fetchArtwork(storeID: String, completion: @escaping (NSImage?) -> Void) {
    let region = Locale.current.region?.identifier ?? "US"
    guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(storeID)&country=\(region)") else { completion(nil); return }
    URLSession.shared.dataTask(with: url) { data, _, _ in
        guard let data = data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = (j["results"] as? [[String: Any]])?.first,
              let u100 = r["artworkUrl100"] as? String,
              let imgURL = URL(string: u100.replacingOccurrences(of: "100x100bb", with: "300x300bb")) else { completion(nil); return }
        URLSession.shared.dataTask(with: imgURL) { d2, _, _ in completion(d2.flatMap { NSImage(data: $0) }) }.resume()
    }.resume()
}

// MARK: - Timer model

/// Seconds from the CPU's hardware counter. Keeps counting through sleep and is immune to clock changes
/// (manual time changes, network time sync, time zone), unlike `Date`.
func hardwareSeconds() -> TimeInterval {
    struct TB { static let r: mach_timebase_info_data_t = { var i = mach_timebase_info_data_t(); mach_timebase_info(&i); return i }() }
    return TimeInterval(mach_continuous_time()) * TimeInterval(TB.r.numer) / TimeInterval(TB.r.denom) / 1e9
}

final class TimerModel {
    enum Mode { case stopwatch, countdown }
    var mode: Mode = .stopwatch
    var running = false
    var target: TimeInterval = 300       // countdown length
    private var accumulated: TimeInterval = 0
    private var startedAt: TimeInterval?     // hardwareSeconds() when it was last started

    var elapsed: TimeInterval { accumulated + (running ? hardwareSeconds() - (startedAt ?? hardwareSeconds()) : 0) }
    var display: TimeInterval { mode == .stopwatch ? elapsed : max(0, target - elapsed) }
    var finished: Bool { mode == .countdown && elapsed >= target }

    func toggle() {
        if running { accumulated = elapsed; running = false; startedAt = nil }
        else { if finished { reset() }; startedAt = hardwareSeconds(); running = true }
    }
    var started: Bool { running || accumulated > 0 }
    func reset() { running = false; accumulated = 0; startedAt = nil; target = 300 }
    func startStopwatch() { reset(); mode = .stopwatch; toggle() }
    func startCountdown(minutes: Int) { reset(); mode = .countdown; target = TimeInterval(minutes * 60); toggle() }
    func switchMode() { reset(); mode = (mode == .stopwatch) ? .countdown : .stopwatch }
    func addMinute() { if mode == .countdown { target += 60 } }

    static func format(_ t: TimeInterval, roundUp: Bool) -> String {
        let s = Int(t.rounded(roundUp ? .up : .down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
    func text() -> String { TimerModel.format(display, roundUp: mode == .countdown) }
}

func mmss(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.down)))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Small views

class Flip: NSView { override var isFlipped: Bool { true } }

/// Rounded album-art tile; shows a music-note placeholder until an image arrives.
final class ArtView: NSView {
    private let note = NSImageView()
    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        note.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        note.contentTintColor = NSColor(white: 1, alpha: 0.55)
        addSubview(note)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); note.frame = bounds }
    func setImage(_ img: NSImage?) {
        layer?.contents = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        note.isHidden = img != nil
    }
}

/// Four animated bars (the "now playing" equalizer).
final class EqView: NSView {
    private var bars: [CALayer] = []
    private var animating = false
    var color: NSColor = accent { didSet { bars.forEach { $0.backgroundColor = color.cgColor } } }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<4 {
            let l = CALayer()
            l.backgroundColor = color.cgColor
            l.cornerRadius = 1.5
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
            l.transform = CATransform3DMakeScale(1, 0.3, 1)
            layer?.addSublayer(l)
            bars.append(l)
        }
        setPlaying(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let bw: CGFloat = 3, gap = (bounds.width - bw * 4) / 3
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in bars.enumerated() {
            l.bounds = CGRect(x: 0, y: 0, width: bw, height: bounds.height)
            l.position = CGPoint(x: bw / 2 + CGFloat(i) * (bw + gap), y: 0)
        }
        CATransaction.commit()
    }
    func setPlaying(_ p: Bool) {
        guard p != animating || bars.first?.animationKeys() == nil && p else { return }
        animating = p
        for (i, l) in bars.enumerated() {
            let current = (l.presentation()?.value(forKeyPath: "transform.scale.y") as? NSNumber)?.doubleValue ?? 0.3
            l.removeAllAnimations()
            if p {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = current; a.toValue = 1.0
                a.duration = 0.42 + Double(i) * 0.11
                a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.timeOffset = Double(i) * 0.13
                l.add(a, forKey: "eq")
            } else {
                l.transform = CATransform3DMakeScale(1, 0.3, 1)
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = current; a.toValue = 0.3
                a.duration = 0.25; a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                l.add(a, forKey: "settle")
            }
        }
    }
}

final class ProgressBar: NSView {
    private let fill = CALayer()
    var fraction: CGFloat = 0 {
        didSet {
            guard fraction != oldValue else { return }
            let from = fill.presentation()?.frame ?? fill.frame
            relayout()
            let a = CABasicAnimation(keyPath: "bounds.size.width")
            a.fromValue = from.width; a.toValue = fill.bounds.width
            a.duration = 0.15; a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.add(a, forKey: "progress")
        }
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        layer?.cornerRadius = 2.5
        fill.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
        fill.cornerRadius = 2.5
        layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); relayout() }
    private func relayout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * min(max(fraction, 0), 1), height: bounds.height)
        CATransaction.commit()
    }
}

/// Pill-shaped battery with a coloured fill (like the iPhone charging banner).
final class BatteryGlyph: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var color: NSColor = bannerGreen { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let tipW: CGFloat = 3
        let body = NSRect(x: 0, y: 0, width: bounds.width - tipW - 1, height: bounds.height)
        let shape = NSBezierPath(roundedRect: body, xRadius: 5, yRadius: 5)
        NSColor(white: 1, alpha: 0.28).setFill(); shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        color.setFill()
        let f = min(max(fraction, 0), 1)
        NSRect(x: 0, y: 0, width: f > 0 ? max(5, body.width * f) : 0, height: body.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: bounds.midY - 2.5, width: tipW, height: 5), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Circular progress ring (AirPods battery).
final class RingView: NSView {
    private let track = CAShapeLayer(), prog = CAShapeLayer()
    var fraction: CGFloat = 0 {
        didSet {
            guard fraction != oldValue else { return }
            let from = prog.presentation()?.strokeEnd ?? prog.strokeEnd
            let to = min(max(fraction, 0), 1)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            prog.strokeEnd = to; CATransaction.commit()
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = from; a.toValue = to; a.duration = 0.4
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            prog.add(a, forKey: "level")
        }
    }
    var color: NSColor = bannerGreen { didSet { prog.strokeColor = color.cgColor } }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for l in [track, prog] { l.fillColor = nil; l.lineWidth = 3.5; l.lineCap = .round; layer?.addSublayer(l) }
        track.strokeColor = NSColor(white: 1, alpha: 0.22).cgColor
        prog.strokeColor = color.cgColor
        prog.strokeEnd = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 2.5,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)   // from the top, clockwise
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [track, prog] { l.frame = bounds; l.path = path }
        CATransaction.commit()
    }
}

/// The original HUD's bar: 16 flat cells; while the pointer is over the HUD they melt into a smooth slider with a
/// knob. Eased fill; click or drag sets the level. The view is tall (easy to hit) but draws thin.
final class LevelBar: NSView {
    private static let count = 16
    private static let knobW: CGFloat = 18, knobH: CGFloat = 14, lineH: CGFloat = 4
    private let seg = CALayer(), slider = CALayer()
    private var track: [CALayer] = [], fill: [CALayer] = []
    private let sTrack = CALayer(), sFill = CALayer(), knob = CALayer()
    private var shown: Float = 0, target: Float = 0
    private var timer: Timer?
    var onChange: ((Float) -> Void)?

    /// Pointer over the HUD: cells -> slider with a knob.
    var sliderMode = false {
        didSet {
            guard sliderMode != oldValue else { return }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            seg.opacity = sliderMode ? 0 : 1
            slider.opacity = sliderMode ? 1 : 0
            CATransaction.commit()
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(seg); layer?.addSublayer(slider)
        for _ in 0..<LevelBar.count {
            let t = CALayer(); t.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor; t.cornerRadius = 1.5; t.masksToBounds = true
            let f = CALayer(); f.backgroundColor = NSColor(white: 1, alpha: 0.95).cgColor
            t.addSublayer(f); seg.addSublayer(t); track.append(t); fill.append(f)
        }
        sTrack.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor; sTrack.cornerRadius = LevelBar.lineH / 2
        sFill.backgroundColor = NSColor(white: 1, alpha: 0.95).cgColor;  sFill.cornerRadius = LevelBar.lineH / 2
        knob.backgroundColor = NSColor.white.cgColor; knob.cornerRadius = LevelBar.knobH / 2
        knob.shadowColor = NSColor.black.cgColor; knob.shadowOpacity = 0.35; knob.shadowRadius = 2; knob.shadowOffset = .zero
        slider.addSublayer(sTrack); slider.addSublayer(sFill); slider.addSublayer(knob)
        slider.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() { super.layout(); render() }

    private func render() {
        let n = CGFloat(LevelBar.count), gap: CGFloat = 2, mid = bounds.height / 2
        let cw = (bounds.width - gap * (n - 1)) / n, ch = LevelBar.lineH
        let kw = LevelBar.knobW, kh = LevelBar.knobH
        CATransaction.begin(); CATransaction.setDisableActions(true)
        seg.frame = bounds; slider.frame = bounds
        for i in 0..<LevelBar.count {
            track[i].frame = CGRect(x: CGFloat(i) * (cw + gap), y: mid - ch / 2, width: cw, height: ch)
            let frac = CGFloat(min(max(shown * Float(LevelBar.count) - Float(i), 0), 1))
            fill[i].frame = CGRect(x: 0, y: 0, width: cw * frac, height: ch)
        }
        let cx = kw / 2 + CGFloat(shown) * max(bounds.width - kw, 0)
        sTrack.frame = CGRect(x: 0, y: mid - ch / 2, width: bounds.width, height: ch)
        sFill.frame = CGRect(x: 0, y: mid - ch / 2, width: cx, height: ch)
        knob.frame = CGRect(x: cx - kw / 2, y: mid - kh / 2, width: kw, height: kh)
        CATransaction.commit()
    }

    /// Eased towards the new value; `animated: false` jumps (used while the pointer drags).
    func set(_ v: Float, animated: Bool) {
        target = min(max(v, 0), 1)
        if !animated { shown = target; timer?.invalidate(); timer = nil; render(); return }
        guard timer == nil, abs(shown - target) > 0.002 else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let s = self else { tm.invalidate(); return }
            s.shown += (s.target - s.shown) * 0.3
            if abs(s.target - s.shown) < 0.002 { s.shown = s.target; tm.invalidate(); s.timer = nil }
            s.render()
        }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func pick(_ e: NSEvent) {
        let x = convert(e.locationInWindow, from: nil).x, w = max(bounds.width, 1)
        let frac = sliderMode ? (x - LevelBar.knobW / 2) / max(w - LevelBar.knobW, 1) : x / w   // knob centre follows the pointer
        let v = (Float(frac) * 64).rounded() / 64                                          // 1/64 grid
        set(v, animated: false)
        onChange?(min(max(v, 0), 1))
    }
    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }
}

func makeLabel(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, mono: Bool = false,
               align: NSTextAlignment = .left) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = align
    l.isBezeled = false
    l.lineBreakMode = .byTruncatingTail
    return l
}

func makeSymbolButton(_ name: String, _ pt: CGFloat, _ tint: NSColor) -> NSButton {
    let b = NSButton()
    b.isBordered = false
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleNone
    b.contentTintColor = tint
    b.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pt, weight: .bold))
    return b
}

func setSymbol(_ b: NSButton, _ name: String, _ pt: CGFloat) {
    b.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pt, weight: .bold))
}

// MARK: - Notch silhouette
//
// Like the hardware notch the shape is wider at the very top than below it: the top corners flare OUT into
// the top edge of the screen (concave "ears", radius `earRadius`) and the bottom corners are convex.
// Idle island = 6pt ears / 14pt bottom corners (the notch itself); both ease up as it grows into a card.
func earRadius(_ h: CGFloat) -> CGFloat { min(18, max(6, 6 + (h - 40) * 0.2)) }
func bottomRadius(_ h: CGFloat) -> CGFloat { min(26, max(14, 14 + (h - 40) * 0.18)) }

func notchPath(_ w: CGFloat, _ h: CGFloat, earL: Bool = true, earR: Bool = true) -> CGPath {
    let t = earRadius(h)
    let tl = earL ? t : 0, tr = earR ? t : 0
    let b = max(0, min(bottomRadius(h), h - t, (w - tl - tr) / 2))
    let p = CGMutablePath()                                     // y grows upward; the top edge is y = h
    p.move(to: CGPoint(x: 0, y: h))
    p.addLine(to: CGPoint(x: w, y: h))
    if earR { p.addArc(center: CGPoint(x: w, y: h - t), radius: t, startAngle: .pi / 2, endAngle: .pi, clockwise: false) }   // right ear
    p.addLine(to: CGPoint(x: w - tr, y: b))
    p.addArc(center: CGPoint(x: w - tr - b, y: b), radius: b, startAngle: 0, endAngle: -.pi / 2, clockwise: true)           // bottom right
    p.addLine(to: CGPoint(x: tl + b, y: 0))
    p.addArc(center: CGPoint(x: tl + b, y: b), radius: b, startAngle: -.pi / 2, endAngle: -.pi, clockwise: true)            // bottom left
    p.addLine(to: CGPoint(x: tl, y: earL ? h - t : h))
    if earL { p.addArc(center: CGPoint(x: 0, y: h - t), radius: t, startAngle: 0, endAngle: .pi / 2, clockwise: false) }    // left ear
    p.closeSubpath()
    return p
}

// MARK: - Content (flipped: y grows downward from the top of the island)

enum Body { case none, hud, banner, alert, media, timer }
enum LevelKind { case volume, brightness }

/// Everything that can be a live activity, in the order they are listed when several run at once.
enum ActKind: Hashable { case media, timer, charging, lowBattery, airpods }
let allKinds: [ActKind] = [.media, .timer, .charging, .airpods, .lowBattery]

/// The two small views an activity can be drawn with: a 24pt icon, and a detail (time, %, equalizer, ring).
final class SlotItem {
    let icon: NSView
    let detail: NSView
    let detailSize: CGSize
    init(icon: NSView, detail: NSView, detailSize: CGSize) { self.icon = icon; self.detail = detail; self.detailSize = detailSize }
    var pillWidth: CGFloat { 24 + 6 + detailSize.width }
}

/// One critically-damped-ish spring channel.
struct SpringV {
    var cur: CGFloat = 0, vel: CGFloat = 0, tgt: CGFloat = 0
    mutating func step(_ h: CGFloat, _ k: CGFloat, _ c: CGFloat) { vel += (-k * (cur - tgt) - c * vel) * h; cur += vel * h }
    var settled: Bool { abs(cur - tgt) < 0.1 && abs(vel) < 2 }
    mutating func snap() { cur = tgt; vel = 0 }
    mutating func jump(_ v: CGFloat) { cur = v; tgt = v; vel = 0 }
}

/// A window (the island itself, the detached icon, the pill under the notch) and the springs that move it.
final class Piece {
    let panel: NSPanel
    var x = SpringV(), w = SpringV(), h = SpringV(), ty = SpringV()    // left edge, width, height, distance from the top of the screen
    var fullW: CGFloat = 1
    var active = false      // wants to be on screen
    var visible = false     // is on screen (an inactive piece stays until it has shrunk away)
    init(panel: NSPanel) { self.panel = panel }
    var settled: Bool { x.settled && w.settled && h.settled && ty.settled }
    func snap() { x.snap(); w.snap(); h.snap(); ty.snap() }
}

/// The detached icon circle and the pill under the notch: black capsules holding slot views, centred.
final class PillView: NSView {
    var onPress: (() -> Void)?
    var onRelease: ((Bool) -> Void)?
    var items: [SlotItem] = [] { didSet { needsLayout = true } }
    var single: (view: NSView, size: CGSize)? { didSet { needsLayout = true } }   // one view, centred (the second notch)
    var withDetail = false { didSet { needsLayout = true } }
    var notchStyle = false { didSet { needsLayout = true } }    // a second notch: attached to the top edge of the screen
    private let shapeMask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = shapeMask
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let r = bounds.height / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shapeMask.frame = bounds
        shapeMask.path = notchStyle ? notchPath(bounds.width, bounds.height)
                                    : CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()
        if let one = single {
            one.view.frame = NSRect(x: (bounds.width - one.size.width) / 2, y: (bounds.height - one.size.height) / 2, width: one.size.width, height: one.size.height)
        }
        let widths = items.map { withDetail ? $0.pillWidth : 24 }
        let total = widths.reduce(0, +) + 16 * CGFloat(max(items.count - 1, 0))
        var x = (bounds.width - total) / 2
        for (it, wd) in zip(items, widths) {
            it.icon.frame = NSRect(x: x, y: (bounds.height - 24) / 2, width: 24, height: 24)
            if withDetail {
                it.detail.frame = NSRect(x: x + 30, y: (bounds.height - it.detailSize.height) / 2,
                                         width: it.detailSize.width, height: it.detailSize.height)
            }
            x += wd + 16
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return nil }
        return bounds.contains(convert(point, from: sv)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func mouseUp(with event: NSEvent) { onRelease?(bounds.contains(convert(event.locationInWindow, from: nil))) }
}

final class Content: Flip {
    var notchH: CGFloat = 32
    var bandH: CGFloat = 32          // height of the top band the wings live in (taller while compact)
    var body: Body = .none
    var ending = false               // everything is going away: fade slowly
    var leftView: NSView?            // slot views drawn beside the notch (managed by App)
    var rightView: NSView?
    var rightSize = CGSize(width: 24, height: 24)
    var leftSize = CGSize(width: 24, height: 24)
    private var lastAlpha: [ObjectIdentifier: CGFloat] = [:]

    // media body
    let art = ArtView(radius: 10)
    let titleL = makeLabel(15, .semibold, .white)
    let artistL = makeLabel(14, .regular, NSColor(white: 1, alpha: 0.55))
    let bodyEq = EqView()
    let progress = ProgressBar()
    let elapsedL = makeLabel(11, .medium, NSColor(white: 1, alpha: 0.5), mono: true)
    let remainL = makeLabel(11, .medium, NSColor(white: 1, alpha: 0.5), mono: true, align: .right)
    let prevB = makeSymbolButton("backward.fill", 24, .white)
    let playB = makeSymbolButton("pause.fill", 30, .white)
    let nextB = makeSymbolButton("forward.fill", 24, .white)
    // timer body
    let pauseB = makeSymbolButton("pause.fill", 20, accent)
    let cancelB = makeSymbolButton("xmark", 18, .white)
    let tLabel = makeLabel(13, .semibold, accent, align: .right)
    let tTime = makeLabel(34, .semibold, accent, mono: true, align: .right)
    // banner body (charging / AirPods): a pill as tall as the notch, content on both sides of it
    var bannerIsAir = false
    let bTitle = makeLabel(16, .semibold, .white)
    let bPct = makeLabel(16, .semibold, bannerGreen, mono: true, align: .right)
    let bGlyph = BatteryGlyph()
    let bAir = NSImageView()
    let bRing = RingView()
    // volume / brightness HUD: icon on the left of the notch, level bar on the right
    let hIcon = NSImageView()
    let hBar = LevelBar()
    var hIconName = ""
    // alert body
    let alertL = makeLabel(15, .semibold, .white, align: .center)

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in [pauseB, cancelB] { b.wantsLayer = true; b.layer?.cornerRadius = 22 }
        pauseB.layer?.backgroundColor = accent.withAlphaComponent(0.28).cgColor
        cancelB.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        hIcon.contentTintColor = .white
        for v in all { addSubview(v); v.alphaValue = 0 }
    }
    required init?(coder: NSCoder) { fatalError() }

    var all: [NSView] {
        [art, titleL, artistL, bodyEq, progress, elapsedL, remainL,
         prevB, playB, nextB, pauseB, cancelB, tLabel, tTime, alertL, bTitle, bPct, bGlyph, bAir, bRing, hIcon, hBar]
    }

    /// Cover + title + artist: tapping it opens the app that is playing.
    var sourceRect: NSRect { art.frame.union(titleL.frame).union(artistL.frame) }

    override func layout() {
        super.layout()
        let w = bounds.width, pad: CGFloat = 16, top = notchH + 2
        // wings: the icon tile gets the same margin on the left, top and bottom
        let tile: CGFloat = 24
        let m = max((bandH - tile) / 2, 0)
        let leftInset: CGFloat = bandH > notchH ? m : 14        // compact pill: even margins; expanded: wing icons
        let rightInset: CGFloat = bandH > notchH ? (rightSize.width > tile ? m + 6 : m) : 14
        leftView?.frame = NSRect(x: leftInset, y: (bandH - leftSize.height) / 2, width: leftSize.width, height: leftSize.height)
        rightView?.frame = NSRect(x: w - rightInset - rightSize.width, y: (bandH - rightSize.height) / 2,
                                  width: rightSize.width, height: rightSize.height)
        // media
        art.frame = NSRect(x: pad, y: top, width: 48, height: 48)
        let tx = pad + 48 + 12, tw = max(0, w - tx - pad - 26)
        titleL.frame = NSRect(x: tx, y: top + 4, width: tw, height: 20)
        artistL.frame = NSRect(x: tx, y: top + 25, width: tw, height: 18)
        bodyEq.frame = NSRect(x: w - pad - 20, y: top + 6, width: 20, height: 20)
        progress.frame = NSRect(x: pad, y: top + 56, width: w - 2 * pad, height: 4)
        elapsedL.frame = NSRect(x: pad, y: top + 62, width: 60, height: 14)
        remainL.frame = NSRect(x: w - pad - 60, y: top + 62, width: 60, height: 14)
        let cy = top + 76
        playB.frame = NSRect(x: w / 2 - 25, y: cy, width: 50, height: 32)
        prevB.frame = NSRect(x: w / 2 - 25 - 70, y: cy, width: 50, height: 32)
        nextB.frame = NSRect(x: w / 2 - 25 + 70, y: cy, width: 50, height: 32)
        // timer
        pauseB.frame = NSRect(x: pad, y: top + 2, width: 44, height: 44)
        cancelB.frame = NSRect(x: pad + 52, y: top + 2, width: 44, height: 44)
        tLabel.frame = NSRect(x: w - pad - 150, y: top - 2, width: 150, height: 16)
        tTime.frame = NSRect(x: w - pad - 150, y: top + 10, width: 150, height: 42)
        // banner (left/right inset 14 inside the body)
        bTitle.frame = NSRect(x: 14, y: (notchH - 20) / 2, width: 100, height: 20)
        bAir.frame = NSRect(x: 14, y: (notchH - 26) / 2, width: 30, height: 26)
        bGlyph.frame = NSRect(x: w - 14 - 34, y: (notchH - 15) / 2, width: 34, height: 15)
        bPct.frame = NSRect(x: w - 14 - 34 - 8 - 56, y: (notchH - 20) / 2, width: 56, height: 20)
        bRing.frame = NSRect(x: w - 14 - 26, y: (notchH - 26) / 2, width: 26, height: 26)
        // HUD
        hIcon.frame = NSRect(x: pad, y: top + 6, width: 24, height: 24)          // below the notch, icon on the left
        hBar.frame = NSRect(x: pad + 24 + 14, y: top + 7, width: max(0, w - pad - 24 - 14 - pad), height: 22)
        // alert
        alertL.frame = NSRect(x: pad, y: notchH + 6, width: w - 2 * pad, height: 22)
    }

    /// Cross-fade every element to what the current shape/body/wings need.
    func applyVisibility(expanded: Bool) {
        let b = body
        let want: [(NSView, Bool)] = [
            (art, expanded && b == .media), (titleL, expanded && b == .media), (artistL, expanded && b == .media),
            (bodyEq, expanded && b == .media), (progress, expanded && b == .media),
            (elapsedL, expanded && b == .media), (remainL, expanded && b == .media),
            (prevB, expanded && b == .media), (playB, expanded && b == .media), (nextB, expanded && b == .media),
            (pauseB, expanded && b == .timer), (cancelB, expanded && b == .timer),
            (tLabel, expanded && b == .timer), (tTime, expanded && b == .timer),
            (alertL, expanded && b == .alert),
            (bTitle, expanded && b == .banner && !bannerIsAir), (bPct, expanded && b == .banner && !bannerIsAir),
            (bGlyph, expanded && b == .banner && !bannerIsAir),
            (bAir, expanded && b == .banner && bannerIsAir), (bRing, expanded && b == .banner && bannerIsAir),
            (hIcon, expanded && b == .hud), (hBar, expanded && b == .hud),
        ]
        for (v, on) in want {
            let a: CGFloat = on ? 1 : 0
            let key = ObjectIdentifier(v)
            if lastAlpha[key] == a { continue }
            lastAlpha[key] = a
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = on ? 0.3 : (ending ? 0.5 : 0.22)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                v.animator().alphaValue = a
            }
        }
    }
}

// MARK: - Island (black body; presses outside buttons go to the app)

final class IslandView: NSView {
    var onPress: (() -> Void)?
    var onRelease: ((Bool) -> Void)?       // true when the finger came up inside the island
    let content = Content(frame: .zero)
    private let shapeMask = CAShapeLayer()
    var earLeft = true { didSet { if earLeft != oldValue { needsLayout = true } } }
    var earRight = true { didSet { if earRight != oldValue { needsLayout = true } } }   // false: the right edge is flush with the notch

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = shapeMask
        content.frame = bounds
        content.autoresizingMask = []                     // laid out by hand: it sits between the ears
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let t = earRadius(bounds.height)
        let l = earLeft ? t : 0, r = earRight ? t : 0
        content.frame = NSRect(x: l, y: 0, width: max(0, bounds.width - l - r), height: bounds.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shapeMask.frame = bounds
        shapeMask.path = notchPath(bounds.width, bounds.height, earL: earLeft, earR: earRight)
        CATransaction.commit()
    }

    var onOpenSource: (() -> Void)?
    private var sourceTapActive = false

    /// Only controls that are actually visible can take a click. (Hidden-by-alpha controls stacked on top of a
    /// visible one used to swallow its clicks.) Everything else is a press on the island itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview, bounds.contains(convert(point, from: sv)) else { return nil }
        let p = content.convert(convert(point, from: sv), from: self)
        for v in content.subviews.reversed() where (v is NSButton || v is LevelBar) && !v.isHidden && v.alphaValue > 0.3 {
            if v.frame.contains(p) { return v }
        }
        return self
    }

    private func overSource(_ e: NSEvent) -> Bool {
        guard content.body == .media, content.art.alphaValue > 0.3 else { return false }
        return content.sourceRect.contains(content.convert(e.locationInWindow, from: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        sourceTapActive = overSource(event)
        if !sourceTapActive { onPress?() }
    }
    override func mouseUp(with event: NSEvent) {
        if sourceTapActive {
            sourceTapActive = false
            if overSource(event) { onOpenSource?() }
            return
        }
        onRelease?(bounds.contains(convert(event.locationInWindow, from: nil)))
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Shape { case collapsed, activity, peek, pressed, expanded }

    // press / long-press state
    var pressing = false                 // finger down on a closed island, long-press not yet fired
    var pressedWhileExpanded = false
    var longPressTimer: Timer?

    // spring-driven window size (smooth, interruptible, velocity-preserving)
    var link: CADisplayLink?
    var mainP: Piece!, sideP: Piece!, pillP: Piece!
    var sideView: PillView!, pillView: PillView!
    var stiffness: CGFloat = 400, damping: CGFloat = 30     // the island's own spring (changes with the shape)
    var signalSources: [DispatchSourceSignal] = []
    var simLux: Double?
    var atRest = true                      // spring has settled
    var popUntil = Date.distantPast       // brief swell-and-return when there is nothing to show

    var panel: NSPanel!
    var view: IslandView!
    var c: Content { view.content }
    let screen: NSScreen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main!
    let timer = TimerModel()
    var shape: Shape = .collapsed

    // inputs
    var pinned = false
    var hoverUntil = Date.distantPast
    var lux = -1.0
    var media: Media?
    var lastPlayingAt = Date.distantPast
    var artwork: NSImage?
    var artColor: NSColor = accent
    var artworkFor = ""
    var artCache: [String: (NSImage, NSColor)] = [:]
    var battery: Battery?
    var banner: BannerKind?
    // live activities, oldest first; at most 5 are shown (the oldest are dropped first)
    var actOrder: [ActKind] = []
    var selected: ActKind?                     // which activity the expanded card shows
    var pressKind: ActKind?
    var airList: [AirPodsInfo] = []
    var slotItems: [ActKind: SlotItem] = [:]
    var lastPlan: Plan?
    var usedViews: [NSView] = []
    // volume / brightness HUD (transient: it goes away by itself, unlike alerts)
    var hudKind: LevelKind = .volume
    var hudValue: Float = 0
    var hudMuted = false
    var hudUntil = Date.distantPast
    var lastVol: Float?, lastMute: Bool?
    let keyTap = MediaKeyTap()
    var brightTarget: Float?
    var brightCur: Float = 0
    var brightTimer: Timer?
    var keyTapTimer: Timer?
    var statusItem: NSStatusItem?
    var bannerSymbol = ""
    var airBusy = false, airBaseline = false
    var mediaBaseline = false            // first poll only records what was already playing
    var prevTimerStarted = false
    var airKnown = Set<String>()
    var alertText: String?
    var alertUntil = Date.distantPast
    var warned20 = false, warned10 = false, notifiedFull = false
    var tick = 0
    var musicBusy = false
    var darkLatched = false          // dark state with hysteresis: set below threshold, cleared above 1.2x
    var sensorMisses = 0

    var notchW: CGFloat {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return screen.frame.width - l.width - r.width
        }
        return 180
    }
    var notchH: CGFloat { max(screen.safeAreaInsets.top, 32) }

    // MARK: activities

    var chargeLevel: Int { demoActsN != nil ? 55 : (battery?.level ?? 0) }
    var lowLevel: Int { demoActsN != nil ? 12 : (battery?.level ?? 0) }
    var airInfo: AirPodsInfo? { demoActsN != nil ? AirPodsInfo(name: "demo", symbol: "airpodspro", level: 80) : airList.first }

    func isActive(_ k: ActKind) -> Bool {
        switch k {
        case .media: return media != nil
        case .timer: return timer.started
        case .charging:   return demoActsN != nil ? demoKinds.contains(k) : (battery?.plugged == true && battery?.charging == true)
        case .lowBattery: return demoActsN != nil ? demoKinds.contains(k) : (battery?.plugged == false && (battery?.level ?? 100) <= 20)
        case .airpods:    return demoActsN != nil ? demoKinds.contains(k) : !airList.isEmpty
        }
    }

    /// Keeps `actOrder` = the running activities in the order they started.
    func syncActivities() {
        for k in allKinds {
            let on = isActive(k), has = actOrder.contains(k)
            if on && !has { actOrder.append(k) } else if !on && has { actOrder.removeAll { $0 == k } }
        }
    }
    var acts: [ActKind] { Array(actOrder.suffix(5)) }

    var cardKind: ActKind? { if let s = selected, acts.contains(s) { return s }; return acts.first }

    func bannerFor(_ k: ActKind) -> BannerKind? {
        switch k {
        case .charging:   return .battery(title: "충전 중", level: chargeLevel, color: bannerGreen)
        case .lowBattery: return .battery(title: "배터리 부족", level: lowLevel, color: lowLevel <= 10 ? bannerRed : accent)
        case .airpods:    let d = airInfo; return .airpods(symbol: d?.symbol ?? "airpods", level: d?.level)
        default:          return nil
        }
    }
    /// What the banner body shows: a one-off banner, or the selected charging / AirPods activity.
    var displayBanner: BannerKind? {
        if let b = banner { return b }
        guard !hudActive, alertText == nil, let k = cardKind else { return nil }
        return bannerFor(k)
    }

    var body: Body {
        if hudActive { return .hud }
        if banner != nil { return .banner }
        if alertText != nil { return .alert }
        switch cardKind {
        case .media?: return .media
        case .timer?: return .timer
        case .charging?, .lowBattery?, .airpods?: return .banner
        case nil: return .none
        }
    }
    var hudActive: Bool { Date() < hudUntil }
    var liveActivity: Bool { hudActive || banner != nil || alertText != nil || !acts.isEmpty }
    let iconWing: CGFloat = 46                                       // space beside the notch for one icon
    /// Space beside the notch when a single activity shows its icon on the left and its detail on the right.
    func wingWidth(_ k: ActKind) -> CGFloat {
        switch k { case .timer: return 66; case .charging, .lowBattery: return 62; default: return 50 }
    }
    /// Charging and low battery show their percentage (not an icon) in the narrow slots beside the notch.
    func showsPercent(_ k: ActKind) -> Bool { k == .charging || k == .lowBattery }
    func slotView(_ k: ActKind) -> (view: NSView, size: CGSize) {
        guard let it = slotItems[k] else { return (NSView(), .zero) }
        return showsPercent(k) ? (it.detail, it.detailSize) : (it.icon, CGSize(width: 24, height: 24))
    }
    func slotWing(_ k: ActKind) -> CGFloat { showsPercent(k) ? 58 : iconWing }     // room beside the notch for that slot
    var bannerWing: CGFloat { if case .airpods? = displayBanner { return 60 }; return 110 }
    var expandedExtra: CGFloat {
        switch body {
        case .media:  return 122
        case .timer:  return 62
        case .banner, .hud: return 0
        default:      return 38
        }
    }

    // MARK: layout plan: which activity goes where

    struct Plan: Equatable {
        var left: ActKind?
        var right: ActKind?
        var rightDetail = false         // right slot shows the detail of the same activity (single activity)
        var side: ActKind?              // the detached icon (exactly 2 activities)
        var pill: [ActKind] = []        // the pill under the notch (3...5 activities)
    }

    func makePlan() -> Plan {
        let a = acts
        if shape == .expanded {
            // an expanded card keeps the other activities as small icons beside the notch
            // only the tall cards have room beside the notch; one-line banners (charging, AirPods...) fill the whole band
            guard !hudActive, banner == nil, alertText == nil, let ck = cardKind, body == .media || body == .timer else { return Plan() }
            let others = a.filter { $0 != ck }
            switch others.count {
            case 0:  return Plan()
            case 1:  return Plan(left: others[0], right: others[0], rightDetail: true)
            default: return Plan(left: others[0], right: others[1])
            }
        }
        switch a.count {
        case 0:  return Plan()
        case 1:  return Plan(left: a[0], right: a[0], rightDetail: true)
        case 2:  return Plan(left: a[0], side: a[1])
        default: return Plan(left: a[0], right: a[1], pill: Array(a.dropFirst(2)))
        }
    }

    // MARK: geometry (screen coordinates, y up)

    var notchLeft: CGFloat { screen.frame.midX - notchW / 2 }
    var notchRight: CGFloat { screen.frame.midX + notchW / 2 }
    var compactH: CGFloat { notchH + 8 }

    func frame(for s: Shape) -> NSRect {
        let a = acts, n = a.count
        let mid = screen.frame.midX, top = screen.frame.maxY
        func r(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: top - h, width: w, height: h) }
        func compact(extra: CGFloat, h: CGFloat) -> NSRect {
            switch n {
            case 0: let w = notchW + extra; return r(mid - w / 2, w, h)
            case 1: let w = notchW + 2 * wingWidth(a[0]) + extra; return r(mid - w / 2, w, h)
            case 2: let wl = slotWing(a[0]); return r(notchLeft - wl - extra, notchW + wl + extra, h)     // grows to the left only
            default: let wl = max(slotWing(a[0]), slotWing(a[1])); let w = notchW + 2 * wl + extra; return r(mid - w / 2, w, h)
            }
        }
        switch s {
        case .collapsed: return r(notchLeft, notchW, notchH)
        case .activity:  return n == 0 ? r(notchLeft, notchW, notchH) : compact(extra: 0, h: compactH)
        case .peek:      return compact(extra: 24, h: n == 0 ? notchH : compactH)           // swells sideways only
        case .pressed:   return compact(extra: 44, h: n == 0 ? notchH + 6 : compactH)      // idle press: sideways AND a little down
        case .expanded:
            let w: CGFloat, h: CGFloat
            switch body {
            case .hud:    (w, h) = (284, notchH + 40)                     // dropped below the notch
            case .banner: (w, h) = (notchW + 2 * bannerWing, notchH)
            default:      (w, h) = (332, notchH + expandedExtra)
            }
            return r(mid - w / 2, w, h)
        }
    }

    /// The detached icon right of the notch (exactly 2 activities).
    func sideRect() -> NSRect? {
        guard shape != .expanded, acts.count == 2 else { return nil }
        let h = compactH
        let body: CGFloat = acts.count == 2 && showsPercent(acts[1]) ? 52 : 40
        let w = body + 2 * earRadius(h)                        // icon body + the two ears
        return NSRect(x: notchRight + sideGap, y: screen.frame.maxY - h, width: w, height: h)
    }
    let sideGap: CGFloat = 3
    let pillH: CGFloat = 34, pillGap: CGFloat = 6
    /// The pill under the notch (3...5 activities): returns its rect and its distance from the top of the screen.
    func pillRect() -> (NSRect, CGFloat)? {
        guard shape != .expanded, acts.count >= 3 else { return nil }
        let items = acts.dropFirst(2).compactMap { slotItems[$0] }
        let w = 28 + items.reduce(0) { $0 + $1.pillWidth } + 16 * CGFloat(max(items.count - 1, 0))
        let ty = compactH + pillGap
        return (NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - ty - pillH, width: w, height: pillH), ty)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = makePanel(frame(for: .collapsed))

        view = IslandView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.content.notchH = notchH
        view.autoresizingMask = [.width, .height]
        view.onPress = { [weak self] in self?.pressBegan() }
        view.onRelease = { [weak self] inside in self?.pressEnded(inside: inside) }
        wire(c.prevB, #selector(prevTapped)); wire(c.playB, #selector(playPauseTapped)); wire(c.nextB, #selector(nextTapped))
        wire(c.pauseB, #selector(timerToggleTapped)); wire(c.cancelB, #selector(timerCancelTapped))
        panel.contentView = view
        panel.orderFrontRegardless()
        makeSticky(panel)
        let r0 = frame(for: .collapsed)
        mainP = Piece(panel: panel); mainP.active = true; mainP.visible = true
        mainP.x.jump(r0.minX); mainP.w.jump(r0.width); mainP.h.jump(r0.height)
        sideView = PillView(frame: .zero); pillView = PillView(frame: .zero); pillView.withDetail = true
        sideView.notchStyle = true
        let sidePanel = makePanel(.zero), pillPanel = makePanel(.zero)
        sidePanel.contentView = sideView; pillPanel.contentView = pillView
        sideP = Piece(panel: sidePanel); pillP = Piece(panel: pillPanel)
        for pv in [sideView!, pillView!] {
            pv.onPress = { [weak self] in self?.pressBegan() }
            pv.onRelease = { [weak self] inside in self?.pressEnded(inside: inside) }
        }
        makeSlotItems()
        link = screen.displayLink(target: self, selector: #selector(animTick(_:)))
        link?.add(to: .main, forMode: .common)
        link?.isPaused = true

        if let t = demoAlert { showAlert(t) }
        if demoTimer { timer.toggle(); pinned = true }
        if demoCharging { showBanner(.battery(title: "충전 중", level: 55, color: bannerGreen)) }
        if demoAirpods { showBanner(.airpods(symbol: "airpodspro", level: 80)) }
        if let n = demoActsN {                                         // --demo-acts N: N fake activities, none pinned open
            if let pick = demoPick {
                if pick.contains("media") { media = Media(title: "승리를 위하여", artist: "트랜스픽션", playing: true, duration: 208, elapsed: 29, readAt: Date(), storeID: "") }
                if pick.contains("timer") { timer.toggle() }
                prevTimerStarted = timer.started
                for (name, k) in [("charging", ActKind.charging), ("airpods", .airpods), ("lowBattery", .lowBattery)] where pick.contains(name) { demoKinds.insert(k) }
            } else {
            if n >= 1 { media = Media(title: "승리를 위하여", artist: "트랜스픽션", playing: true, duration: 208, elapsed: 29, readAt: Date(), storeID: "") }
            if n >= 2 { timer.toggle() }
            prevTimerStarted = timer.started                           // don't auto-open for the demo stopwatch
            for (i, k) in [ActKind.charging, .airpods, .lowBattery].enumerated() where n >= 3 + i { demoKinds.insert(k) }
            }
        }
        if demoVolume { showHUD(.volume, 0.62, muted: false, seconds: 30) }
        if demoBrightness { showHUD(.brightness, 0.78, muted: false, seconds: 30) }
        if demoMedia {
            media = Media(title: "승리를 위하여", artist: "트랜스픽션", playing: true, duration: 208, elapsed: 29, readAt: Date(), storeID: "")
            pinned = ProcessInfo.processInfo.environment["NI_NOPIN"] == nil     // NI_NOPIN=1: start collapsed (screenshots)
        }
        battery = readBattery()
        if let b = battery {   // don't fire "full"/"low" alerts for a state that already existed at launch
            notifiedFull = isFull(b)
            warned20 = !b.plugged && b.level <= 20
            warned10 = !b.plugged && b.level <= 10
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let s = self, s.pinned else { return }
            s.pinned = false                         // click anywhere outside the island closes it
            s.alertText = nil
            s.banner = nil
        }
        if ProcessInfo.processInfo.environment["NI_TEST_SIGNALS"] != nil {     // test hook: simulate the sensor
            signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN); signal(SIGWINCH, SIG_IGN); signal(SIGURG, SIG_IGN)
            let hudSrc = DispatchSource.makeSignalSource(signal: SIGURG, queue: .main)     // SIGURG = pop a brightness HUD (test hook)
            hudSrc.setEventHandler { [weak self] in self?.showHUD(.brightness, 0.6, seconds: 1.8) }
            hudSrc.resume(); signalSources.append(hudSrc)
            let endSrc = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)   // SIGWINCH = every activity ends
            endSrc.setEventHandler { [weak self] in self?.timer.reset(); self?.media = nil; self?.alertText = nil; self?.banner = nil }
            endSrc.resume(); signalSources.append(endSrc)
            for (sig, down) in [(SIGUSR1, true), (SIGUSR2, false)] {
                let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                src.setEventHandler { [weak self] in
                    guard let s = self else { return }
                    s.simLux = down ? 1 : 1000               // goes through the normal edge detection
                }
                src.resume(); signalSources.append(src)
            }
        }
        if ProcessInfo.processInfo.environment["NI_NOSENSOR"] != nil { simLux = 1000 }     // test hook: ignore the real light sensor
        c.hBar.onChange = { [weak self] v in self?.hudDragged(v) }
        view.onOpenSource = { [weak self] in self?.openSourceApp() }
        setupStatusItem()
        keyTap.onKey = { [weak self] code, down, fine in self?.handleMediaKey(code, down, fine) ?? false }
        setupKeyTap()
        refreshUI()
        let stepTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(stepTimer, forMode: .common)       // .common: also runs while a menu is open or a drag is in progress
    }

    func makePanel(_ frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return p
    }

    func symbolView(_ name: String, _ pt: CGFloat, _ tint: NSColor) -> NSImageView {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pt, weight: .semibold))
        v.contentTintColor = tint
        return v
    }

    func makeSlotItems() {
        slotItems[.media] = SlotItem(icon: ArtView(radius: 6), detail: EqView(), detailSize: CGSize(width: 20, height: 16))
        slotItems[.timer] = SlotItem(icon: symbolView("timer", 16, accent),
                                     detail: makeLabel(13, .semibold, accent, mono: true, align: .right), detailSize: CGSize(width: 46, height: 18))
        slotItems[.charging] = SlotItem(icon: symbolView("bolt.fill", 15, bannerGreen),
                                        detail: makeLabel(13, .semibold, bannerGreen, mono: true, align: .center), detailSize: CGSize(width: 38, height: 18))
        slotItems[.lowBattery] = SlotItem(icon: symbolView("battery.25percent", 16, bannerRed),
                                          detail: makeLabel(13, .semibold, bannerRed, mono: true, align: .center), detailSize: CGSize(width: 38, height: 18))
        slotItems[.airpods] = SlotItem(icon: symbolView("airpods", 17, .white), detail: RingView(), detailSize: CGSize(width: 24, height: 24))
    }

    func wire(_ b: NSButton, _ sel: Selector) { b.target = self; b.action = sel }

    // MARK: actions

    @objc func prevTapped() { haptic(); if demoMedia { return }; sendMediaCommand(5); pollSoon() }
    @objc func nextTapped() { haptic(); if demoMedia { return }; sendMediaCommand(4); pollSoon() }
    @objc func playPauseTapped() {
        haptic()
        if var m = media {                           // flip the icon at once; the next poll confirms it
            m.elapsed = m.elapsedNow; m.readAt = Date(); m.playing.toggle()
            if m.playing { lastPlayingAt = Date() }
            media = m
        }
        if !demoMedia { sendMediaCommand(2); pollSoon() }
        refreshUI()
    }
    // MARK: menu bar item

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "NotchIsland")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        if ProcessInfo.processInfo.environment["NI_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let w = item.button?.window
                FileHandle.standardError.write("status item: visible=\(item.isVisible) window=\(String(describing: w?.frame)) onscreen=\(w?.isVisible ?? false) screen=\(String(describing: w?.screen?.frame))\n".data(using: .utf8)!)
            }
        }
    }

    /// Rebuilt every time it opens, so the items match what is running right now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector, _ tag: Int = 0, key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self; i.tag = tag; menu.addItem(i)
        }
        if timer.started {
            menu.addItem(withTitle: (timer.mode == .stopwatch ? "스톱워치 " : "타이머 ") + timer.text(), action: nil, keyEquivalent: "").isEnabled = false
            add(timer.running ? "일시정지" : "계속", #selector(menuToggleTimer))
            add("취소", #selector(menuCancelTimer))
        } else {
            add("스톱워치 시작", #selector(menuStopwatch))
            let sub = NSMenu()
            for m in [1, 3, 5, 10, 15, 30] {
                let i = NSMenuItem(title: "\(m)분", action: #selector(menuCountdown(_:)), keyEquivalent: "")
                i.target = self; i.tag = m; sub.addItem(i)
            }
            let parent = NSMenuItem(title: "타이머", action: nil, keyEquivalent: "")
            parent.submenu = sub; menu.addItem(parent)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "NotchIsland 종료", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
    }

    @objc func menuStopwatch() { timer.startStopwatch(); refreshUI() }
    @objc func menuCountdown(_ sender: NSMenuItem) { timer.startCountdown(minutes: sender.tag); refreshUI() }
    @objc func menuToggleTimer() { timer.toggle(); refreshUI() }
    @objc func menuCancelTimer() { timer.reset(); refreshUI() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    /// Bring the app that is playing to the front (Music, Spotify, the browser with the video...).
    func openSourceApp() {
        haptic(.alignment)
        guard let id = media?.bundleID, !id.isEmpty else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            running.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        pinned = false                               // go back to the compact island once the app is in front
    }

    @objc func timerToggleTapped() { haptic(); timer.toggle(); refreshUI() }
    @objc func timerCancelTapped() { haptic(); timer.reset(); refreshUI() }
    func pollSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pollMusic() } }

    /// Which activity is under the pointer. Anything on the notch itself or to the left of it is the activity attached
    /// to the notch on the left (the first one); the right wing, the detached icon and the pill pick their own.
    func kindAtMouse() -> ActKind? {
        let a = acts
        guard !a.isEmpty else { return nil }
        let m = NSEvent.mouseLocation
        if sideP.active, a.count == 2, sideP.panel.frame.insetBy(dx: -6, dy: -6).contains(m) { return a[1] }
        if pillP.active, a.count >= 3, pillP.panel.frame.insetBy(dx: -6, dy: -6).contains(m) {
            let items = Array(a.dropFirst(2)), f = pillP.panel.frame
            return items[min(items.count - 1, max(0, Int((m.x - f.minX) / max(f.width, 1) * CGFloat(items.count))))]
        }
        if a.count >= 3, m.x > notchRight { return a[1] }
        return a[0]
    }

    /// Finger down: react at once (swell + haptic). With something running, a quick tap opens it on release,
    /// and holding opens it after 0.25s without waiting for the release. With nothing running it pops out and back.
    func pressBegan() {
        haptic(.alignment)
        pressKind = kindAtMouse()
        pressedWhileExpanded = (shape == .expanded)
        if pressedWhileExpanded { return }           // already open: the release (a tap) closes it
        if !liveActivity {                           // nothing to show: pop out a little and go straight back in
            popUntil = Date().addingTimeInterval(0.22)
            return
        }
        pressing = true
        longPressTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let s = self, s.pressing else { return }
            let hit = s.frame(for: s.shape).insetBy(dx: -40, dy: -40)
            guard hit.contains(NSEvent.mouseLocation) else { return }   // dragged away while holding: do nothing
            s.pressing = false
            s.selected = s.pressKind
            s.pinned = true                          // popped out: stays out until you click elsewhere
            haptic(.levelChange)
        }
        RunLoop.main.add(t, forMode: .common)
        longPressTimer = t
    }

    func pressEnded(inside: Bool) {
        longPressTimer?.invalidate(); longPressTimer = nil
        let wasPressing = pressing
        pressing = false
        if wasPressing && inside && liveActivity {   // a quick tap (trackpad click / tap-to-click) opens it
            selected = pressKind
            pinned = true
            haptic(.levelChange)
        }
        if pressedWhileExpanded && inside {          // tapping the open island shrinks it back
            if hudActive { hudUntil = .distantPast }
            else { pinned = false; alertText = nil; banner = nil }
            haptic(.levelChange)
        }
        pressedWhileExpanded = false
    }

    // MARK: sensor touch (covering the ambient light sensor)

    /// Covered. Open island -> shrinks back. Nothing running -> pops out and straight back in.
    /// Something running -> reacts at once; keep it covered 0.3s and it pops open and stays.
    func sensorTouchBegan() {
        haptic(.alignment)
        if shape == .expanded || pinned {
            if hudActive { hudUntil = .distantPast } else { pinned = false; alertText = nil; banner = nil }
            haptic(.levelChange)
            return
        }
        if !liveActivity { popUntil = Date().addingTimeInterval(0.22); return }
        pressing = true
        longPressTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let s = self, s.pressing, s.darkLatched else { return }   // still covered
            s.pressing = false
            s.selected = s.acts.first                // touching the sensor picks the activity attached to the notch (left)
            s.pinned = true
            haptic(.levelChange)
        }
        RunLoop.main.add(t, forMode: .common)
        longPressTimer = t
    }

    /// Uncovered before the long press fired: just settles back.
    func sensorTouchEnded() {
        longPressTimer?.invalidate(); longPressTimer = nil
        pressing = false
    }

    // MARK: volume / brightness HUD

    func showHUD(_ kind: LevelKind, _ value: Float, muted: Bool = false, seconds: TimeInterval = 1.8) {
        hudKind = kind; hudValue = value; hudMuted = muted
        hudUntil = Date().addingTimeInterval(seconds)
        refreshUI()
    }

    /// Volume changed by something else (menu bar slider, headphones, another app): show it too.
    func pollVolume() {
        guard let v = SystemLevels.volume(), let m = SystemLevels.muted() else { return }
        defer { lastVol = v; lastMute = m }
        guard let lv = lastVol, let lm = lastMute else { return }              // first read is the baseline
        if abs(v - lv) > 0.004 || m != lm { showHUD(.volume, v, muted: m || v < 0.001) }
    }

    /// Media keys, once the Accessibility permission has been granted. Returns true when the key was handled.
    func handleMediaKey(_ code: Int, _ down: Bool, _ fine: Bool) -> Bool {
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        func snap(_ v: Float) -> Float { (v / step).rounded() * step }
        switch code {
        case 0, 1, 7:                                                          // volume up / down, mute
            guard SystemLevels.volumeControllable else { return false }         // e.g. HDMI output: leave it to the system
            guard down else { return true }
            let wasMuted = SystemLevels.muted() ?? false
            let cur = SystemLevels.volume() ?? 0
            if code == 7 {
                let now = !wasMuted
                SystemLevels.setMuted(now)
                showHUD(.volume, cur, muted: now || cur < 0.001)
                return true
            }
            if wasMuted { SystemLevels.setMuted(false) }
            let nv = min(1, max(0, snap(cur) + (code == 0 ? step : -step)))
            SystemLevels.setVolume(nv)
            showHUD(.volume, nv, muted: nv < 0.001)
            return true
        case 2, 3:                                                             // brightness up / down
            guard SystemLevels.brightnessControllable else { return false }
            guard down else { return true }
            let cur = brightTarget ?? SystemLevels.brightness() ?? 0     // chain presses from where the glide is heading
            let nb = min(1, max(0, snap(cur) + (code == 2 ? step : -step)))
            rampBrightness(to: nb)
            showHUD(.brightness, nb)
            return true
        default:
            return false                                                       // keyboard backlight etc.: untouched
        }
    }

    /// Eases the real brightness to `t` (~0.25s) instead of jumping a whole step at once.
    func rampBrightness(to t: Float) {
        brightTarget = t
        guard brightTimer == nil else { return }
        brightCur = SystemLevels.brightness() ?? t
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let s = self, let target = s.brightTarget else { tm.invalidate(); self?.brightTimer = nil; return }
            let d = target - s.brightCur
            if abs(d) < 0.004 {
                s.brightCur = target; SystemLevels.setBrightness(target)
                s.brightTarget = nil; tm.invalidate(); s.brightTimer = nil
                return
            }
            s.brightCur += d * 0.22                                            // ease-out
            SystemLevels.setBrightness(s.brightCur)
        }
        RunLoop.main.add(timer, forMode: .common); brightTimer = timer
    }

    /// The pointer set the level on the HUD bar.
    func hudDragged(_ v: Float) {
        let demo = demoVolume || demoBrightness                                 // demos never touch the real levels
        switch hudKind {
        case .volume:
            if !demo { if SystemLevels.muted() == true { SystemLevels.setMuted(false) }; SystemLevels.setVolume(v) }
            showHUD(.volume, v, muted: v < 0.001, seconds: 1.8)
        case .brightness:
            brightTarget = nil                                                  // cancel any glide: follow the pointer directly
            if !demo { SystemLevels.setBrightness(v) }
            showHUD(.brightness, v, seconds: 1.8)
        }
    }

    func setupKeyTap() {
        guard ProcessInfo.processInfo.environment["NI_NOKEYTAP"] == nil else { return }     // test hook
        if !AXIsProcessTrusted() {
            // Prompt on launch whenever access is missing, including after permission is revoked.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        func tryInstall() {
            if !keyTap.isActive, AXIsProcessTrusted(), keyTap.install(),
               ProcessInfo.processInfo.environment["NI_DEBUG"] != nil {
                FileHandle.standardError.write("media key tap installed\n".data(using: .utf8)!)
            }
        }
        tryInstall()
        let kt = Timer(timeInterval: 3, repeats: true) { _ in tryInstall() }   // picks up a later grant
        RunLoop.main.add(kt, forMode: .common); keyTapTimer = kt
    }

    func showBanner(_ k: BannerKind) {
        banner = k
        pinned = true                                // stays until you click somewhere else
        haptic(.levelChange)
    }

    func showAlert(_ text: String, seconds: TimeInterval = 3.5) {
        if let cur = alertText, Date() < alertUntil, cur != text { alertText = cur + "  ·  " + text }   // merge simultaneous alerts
        else { alertText = text }
        alertUntil = Date().addingTimeInterval(seconds)
        pinned = true                                // alerts open it and it stays until an outside click
        haptic(.levelChange)
    }

    // MARK: periodic work

    func step() {
        tick += 1
        let now = Date()

        // hover: pointer inside the current shape (a little padded) nudges the island
        let m = NSEvent.mouseLocation
        let pad: CGFloat = shape == .expanded ? 8 : 4
        let hit = frame(for: shape).insetBy(dx: -pad, dy: -pad)
        let probe = NSRect(x: hit.minX, y: hit.minY, width: hit.width, height: hit.height + 4) // include the screen's top edge
        if probe.contains(m) {
            hoverUntil = now.addingTimeInterval(0.25)
            if hudActive { hudUntil = max(hudUntil, now.addingTimeInterval(0.9)) }   // pointer on the HUD: keep it
        }
        let overHUD = hudActive && probe.contains(m)
        if c.hBar.sliderMode != overHUD { c.hBar.sliderMode = overHUD }              // cells melt into a slider under the pointer

        if tick % 2 == 0 {                         // 30Hz: the ambient light sensor is the touch sensor
            let v = simLux ?? als_read()              // simLux is only set by the test hook below
            if v >= 0 { lux = v; sensorMisses = 0 }   // raw value, no smoothing; hysteresis below prevents flicker
            else { sensorMisses += 1; if sensorMisses >= 60 { lux = -1 } }   // ~2s of silence: stop trusting old data
            let wasCovered = darkLatched
            if lux >= 0 && lux < threshold { darkLatched = true }            // covered  = finger down
            else if lux < 0 || lux > threshold * 1.2 { darkLatched = false } // uncovered = finger up
            if darkLatched && !wasCovered { sensorTouchBegan() }
            else if !darkLatched && wasCovered { sensorTouchEnded() }
        }
        if tick % 4 == 0 { pollVolume() }          // 15Hz: volume changes from anywhere (keys, menu bar, headphones)
        if tick % 120 == 0 { pollBattery() }       // 2s
        if tick % 120 == 47 { pollMusic() }        // 2s, offset from battery
        if let m = media, !m.playing, !demoMedia, demoActsN == nil, shape != .expanded,
           now.timeIntervalSince(lastPlayingAt) > 4 { media = nil }     // paused for a while: let it go
        if tick % 360 == 211 { pollAirPods() }     // 6s

        if timer.started && !prevTimerStarted { selected = .timer; pinned = true; haptic(.levelChange) }   // stopwatch started: open it
        prevTimerStarted = timer.started
        if timer.finished {                        // countdown just hit zero
            timer.reset()
            NSSound.beep()
            showAlert("⏰ 타이머 종료", seconds: 6)
        }

        if tick % 6 == 0 { refreshUI() }           // content at 10Hz; shape/hover/press every frame
        applyShape()
    }

    func pollBattery() {
        guard let b = readBattery() else { return }
        defer { battery = b }
        guard let old = battery else { return }
        if b.plugged != old.plugged {
            showBanner(.battery(title: b.plugged ? "충전 중" : "충전 해제", level: b.level, color: b.plugged ? bannerGreen : .white))
            notifiedFull = false
        }
        if b.plugged {
            warned20 = false; warned10 = false
            if isFull(b) && !notifiedFull { notifiedFull = true; showBanner(.battery(title: "충전 완료", level: b.level, color: bannerGreen)) }
        } else {
            if b.level <= 10 && !warned10 { warned10 = true; warned20 = true; showBanner(.battery(title: "배터리 부족", level: b.level, color: bannerRed)) }
            else if b.level <= 20 && !warned20 { warned20 = true; showBanner(.battery(title: "배터리 부족", level: b.level, color: accent)) }
        }
    }

    func pollAirPods() {
        guard !airBusy else { return }
        airBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = queryAirPods()
            DispatchQueue.main.async { self?.airBusy = false; self?.applyAirPods(list) }
        }
    }

    func applyAirPods(_ list: [AirPodsInfo]) {
        airList = list
        if airBaseline {                             // the first poll only records what is already connected
            for d in list where !airKnown.contains(d.name) { showBanner(.airpods(symbol: d.symbol, level: d.level)) }
        }
        airKnown = Set(list.map { $0.name }); airBaseline = true
    }

    func pollMusic() {
        guard !musicBusy, !demoMedia, demoActsN == nil, ProcessInfo.processInfo.environment["NI_NOMEDIA"] == nil else { return }   // NI_NOMEDIA=1: test hook
        musicBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = queryNowPlaying()
            DispatchQueue.main.async { self?.applyPolled(r); self?.musicBusy = false }
        }
    }

    func applyPolled(_ result: PollResult) {
        let r: Media
        switch result {
        case .failed: return                         // a failed lookup must not make the island vanish
        case .nothing: media = nil; mediaBaseline = true; return
        case .media(let m): r = m
        }
        defer { mediaBaseline = true }
        if r.playing { lastPlayingAt = Date() }
        // keep a paused track around for a while so it can be resumed from the island
        // A paused track is only KEPT while it is already showing (so it can be resumed from the island).
        // Once it has gone away it never comes back by itself: only playing again starts a new activity.
        if !r.playing {
            guard media != nil, shape == .expanded || Date().timeIntervalSince(lastPlayingAt) < 4 else { media = nil; return }
        }
        let isNew = media == nil || media?.title != r.title
        media = r
        loadArtwork(for: r.storeID)
        if mediaBaseline && r.playing && isNew {     // playback just started / the track changed: open the card at once
            selected = .media
            pinned = true
            haptic(.levelChange)
        }
    }

    func loadArtwork(for id: String) {
        guard id != artworkFor else { return }
        artworkFor = id
        artwork = nil; artColor = accent
        guard !id.isEmpty else { return }
        if let hit = artCache[id] { artwork = hit.0; artColor = hit.1; return }
        fetchArtwork(storeID: id) { [weak self] img in
            guard let img = img else { return }
            let col = averageColor(img)
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.artCache[id] = (img, col)
                if s.artworkFor == id { s.artwork = img; s.artColor = col }
            }
        }
    }

    // MARK: rendering

    func setText(_ f: NSTextField, _ s: String) { if f.stringValue != s { f.stringValue = s } }

    func refreshUI() {
        syncActivities()
        let b = body
        c.body = b
        c.ending = b == .none && acts.isEmpty
        c.bandH = (shape == .expanded || (shape == .collapsed && atRest)) ? notchH : notchH + 8
        view.earRight = !(shape != .expanded && acts.count == 2)       // 2 activities: the island ends flush with the notch

        // timer pieces
        let timeText = timer.text()
        setText(c.tTime, timeText)
        setText(c.tLabel, timer.mode == .stopwatch ? "스톱워치" : "타이머")
        setSymbol(c.pauseB, timer.running ? "pause.fill" : "play.fill", 20)

        // banner
        if let bn = displayBanner {
            switch bn {
            case .battery(let title, let level, let color):
                c.bannerIsAir = false
                setText(c.bTitle, title); setText(c.bPct, "\(level)%")
                c.bPct.textColor = color
                c.bGlyph.fraction = CGFloat(level) / 100; c.bGlyph.color = color
            case .airpods(let symbol, let level):
                c.bannerIsAir = true
                if symbol != bannerSymbol {
                    bannerSymbol = symbol
                    c.bAir.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 21, weight: .regular))
                    c.bAir.contentTintColor = .white
                }
                c.bRing.fraction = CGFloat(level ?? 0) / 100
            }
        }

        // volume / brightness HUD
        if hudActive {
            let level = hudMuted ? 0 : hudValue
            let name: String
            switch hudKind {
            case .volume:
                name = (hudMuted || hudValue < 0.001) ? "speaker.slash.fill"
                     : hudValue < 0.34 ? "speaker.wave.1.fill" : hudValue < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            case .brightness:
                name = hudValue < 0.5 ? "sun.min.fill" : "sun.max.fill"
            }
            if name != c.hIconName {
                c.hIconName = name
                c.hIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 19, weight: .semibold))
            }
            c.hBar.set(level, animated: true)
        }

        // alert
        setText(c.alertL, alertText ?? "")

        // media pieces
        if let m = media {
            setText(c.titleL, m.title)
            setText(c.artistL, m.artist)
            c.art.setImage(artwork)
            let e = m.elapsedNow
            setText(c.elapsedL, mmss(e))
            setText(c.remainL, m.duration > 0 ? "-" + mmss(m.duration - e) : "")
            c.progress.fraction = m.duration > 0 ? CGFloat(e / m.duration) : 0
            c.progress.isHidden = m.duration <= 0
            setSymbol(c.playB, m.playing ? "pause.fill" : "play.fill", 30)
            c.bodyEq.color = artColor; c.bodyEq.setPlaying(m.playing)
        }

        refreshSlots()
        let plan = makePlan()
        if plan != lastPlan { lastPlan = plan; placeSlots(plan) }
        c.needsLayout = true
        c.applyVisibility(expanded: shape == .expanded)
    }

    /// Updates what the small slot views show.
    func refreshSlots() {
        if let m = media, let it = slotItems[.media], let art = it.icon as? ArtView, let eq = it.detail as? EqView {
            art.setImage(artwork); eq.color = artColor; eq.setPlaying(m.playing)
        }
        if let it = slotItems[.timer], let l = it.detail as? NSTextField { setText(l, timer.text()) }
        if let it = slotItems[.charging], let l = it.detail as? NSTextField { setText(l, "\(chargeLevel)%") }
        if let it = slotItems[.lowBattery], let l = it.detail as? NSTextField {
            setText(l, "\(lowLevel)%")
            let col = lowLevel <= 10 ? bannerRed : accent
            l.textColor = col; (it.icon as? NSImageView)?.contentTintColor = col
        }
        if let it = slotItems[.airpods], let d = airInfo, let ring = it.detail as? RingView, let icon = it.icon as? NSImageView {
            ring.fraction = CGFloat(d.level ?? 0) / 100
            if icon.toolTip != d.symbol {
                icon.toolTip = d.symbol
                icon.image = NSImage(systemSymbolName: d.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
            }
        }
    }

    func fade(_ v: NSView, to a: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = a > 0 ? 0.28 : 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.animator().alphaValue = a
        }
    }

    /// Hands the slot views to the windows that now show them; views that are no longer shown fade out.
    func placeSlots(_ plan: Plan) {
        var now: [NSView] = []
        func use(_ v: NSView, in host: NSView) {
            now.append(v)
            if v.superview !== host { v.removeFromSuperview(); host.addSubview(v); v.alphaValue = 0 }
            if v.alphaValue < 1 { fade(v, to: 1) }
        }
        if let lk = plan.left, let it = slotItems[lk] {
            // a single activity: icon on the left, detail on the right. Several: the compact view (icon, or % for charging)
            let v = plan.rightDetail ? (view: it.icon, size: CGSize(width: 24, height: 24)) : slotView(lk)
            c.leftView = v.view; c.leftSize = v.size
            use(v.view, in: c)
        } else { c.leftView = nil }
        if let rk = plan.right, let it = slotItems[rk] {
            let v = plan.rightDetail ? (view: it.detail, size: it.detailSize) : slotView(rk)
            c.rightView = v.view; c.rightSize = v.size
            use(v.view, in: c)
        } else { c.rightView = nil }
        if let sk = plan.side { let v = slotView(sk); use(v.view, in: sideView); sideView.single = v } else { sideView.single = nil }
        let pitems = plan.pill.compactMap { slotItems[$0] }
        for it in pitems { use(it.icon, in: pillView); use(it.detail, in: pillView) }
        pillView.items = pitems
        let nowIDs = Set(now.map { ObjectIdentifier($0) })
        let stale = usedViews.filter { !nowIDs.contains(ObjectIdentifier($0)) }
        for v in stale { fade(v, to: 0) }
        usedViews = now
        if !stale.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let s = self else { return }
                let keep = Set(s.usedViews.map { ObjectIdentifier($0) })
                for v in stale where !keep.contains(ObjectIdentifier(v)) { v.removeFromSuperview() }
            }
        }
    }

    func desiredShape() -> Shape {
        if !pinned { selected = nil }
        if pinned && !liveActivity && !forceOpen { pinned = false }   // nothing left to show
        if forceOpen || pinned || hudActive { return .expanded }
        if pressing || Date() < popUntil { return .pressed }
        if Date() < hoverUntil { return .peek }       // hovering only nudges it; a long press opens it
        if !acts.isEmpty { return .activity }
        return .collapsed
    }

    func applyShape() {
        syncActivities()                             // the list must be current before deciding what is on screen
        let target = desiredShape()
        if target != shape {
            if target == .peek && shape != .pressed { haptic(.alignment) }   // light tick when the pointer arrives
            shape = target
            refreshUI()                                // wings/body change with the shape
            switch target {
            case .pressed:  stiffness = 520; damping = 42
            case .peek:     stiffness = 380; damping = 37
            case .expanded: stiffness = 300; damping = 30
            case .collapsed: stiffness = 120; damping = 22
            default:        stiffness = 300; damping = 34
            }
        }
        var wake = false
        let r = frame(for: shape)
        if abs(r.minX - mainP.x.tgt) > 0.01 || abs(r.width - mainP.w.tgt) > 0.01 || abs(r.height - mainP.h.tgt) > 0.01 {
            mainP.x.tgt = r.minX; mainP.w.tgt = r.width; mainP.h.tgt = r.height
            wake = true
        }
        if setTarget(sideP, sideRect(), ty: 0, anchorX: notchRight + sideGap) { wake = true }
        let pr = pillRect()
        if setTarget(pillP, pr?.0, ty: pr?.1 ?? compactH + pillGap, anchorX: screen.frame.midX) { wake = true }
        if wake { atRest = false; link?.isPaused = false }
    }

    /// Points an auxiliary window at a rect, or (nil) makes it shrink back into its anchor. Returns true if anything changed.
    func setTarget(_ p: Piece, _ r: NSRect?, ty: CGFloat, anchorX: CGFloat) -> Bool {
        if let r = r {
            var changed = false
            if !p.active {                                    // appears: grows out of its anchor
                p.active = true; changed = true
                p.x.jump(anchorX); p.w.jump(0); p.h.jump(r.height); p.ty.jump(ty)
                p.panel.alphaValue = 0
                p.panel.orderFrontRegardless(); makeSticky(p.panel); p.visible = true
            }
            if abs(p.x.tgt - r.minX) > 0.01 || abs(p.w.tgt - r.width) > 0.01 || abs(p.h.tgt - r.height) > 0.01 || abs(p.ty.tgt - ty) > 0.01 { changed = true }
            p.x.tgt = r.minX; p.w.tgt = r.width; p.h.tgt = r.height; p.ty.tgt = ty; p.fullW = r.width
            return changed
        }
        guard p.active else { return false }
        p.active = false; p.x.tgt = anchorX; p.w.tgt = 0
        return true
    }

    @objc func animTick(_ l: CADisplayLink) {
        let dt = min(max(l.targetTimestamp - l.timestamp, 1.0 / 240), 1.0 / 30)
        let steps = Int((dt * 240).rounded(.up)); let h = dt / CGFloat(steps)
        var allSettled = true
        for p in [mainP!, sideP!, pillP!] where p.active || p.visible {
            let isMain = p === mainP
            let k: CGFloat = isMain ? stiffness : 300, cd: CGFloat = isMain ? damping : 28
            for _ in 0..<steps { p.x.step(h, k, cd); p.w.step(h, k, cd); p.h.step(h, k, cd); p.ty.step(h, k, cd) }
            if isMain {
                // Momentum from an interrupted move must never uncover the hardware notch.
                if p.x.cur > notchLeft { p.x.cur = notchLeft; if p.x.vel > 0 { p.x.vel = 0 } }
                if p.x.cur + p.w.cur < notchRight { p.w.cur = notchRight - p.x.cur; if p.w.vel < 0 { p.w.vel = 0 } }
                if p.h.cur < notchH { p.h.cur = notchH; if p.h.vel < 0 { p.h.vel = 0 } }
            }
            if p.settled { p.snap() } else { allSettled = false }
            if !p.active && p.settled && p.w.cur < 1.5 {          // shrunk away: take the window off screen
                p.panel.orderOut(nil); p.visible = false; p.w.jump(0)
                continue
            }
            if !isMain { p.panel.alphaValue = p.fullW > 0 ? min(1, max(0, p.w.cur / p.fullW)) : 0 }
            p.panel.setFrame(NSRect(x: p.x.cur, y: screen.frame.maxY - p.ty.cur - p.h.cur, width: max(p.w.cur, 1), height: max(p.h.cur, 1)), display: true)
        }
        atRest = mainP.settled
        if allSettled { l.isPaused = true }
    }
}

// One island at a time: a second copy (e.g. a hand-started one while the login item runs) exits quietly.
let instanceLockFD = open(NSTemporaryDirectory() + "com.kusbeoms.NotchIsland.lock", O_CREAT | O_RDWR, 0o600)
if instanceLockFD >= 0 && flock(instanceLockFD, LOCK_EX | LOCK_NB) != 0 {
    FileHandle.standardError.write("NotchIsland is already running.\n".data(using: .utf8)!)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
