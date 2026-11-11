import AppKit
import Accelerate
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
var demoShelf: [String]? = nil          // --demo-shelf path1,path2: start with these files in the shelf (not saved)
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
    case "--demo-shelf": demoShelf = argIt.next()?.split(separator: ",").map(String.init)
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
func makeSticky(_ w: NSWindow) { if ProcessInfo.processInfo.environment["NI_NOOVERLAY"] == nil { Overlay.attach(w) } }   // NI_NOOVERLAY: test hook

func dlog(_ m: String) { if ProcessInfo.processInfo.environment["NI_DEBUG"] != nil { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) } }

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
private let mediaCommandQueue = DispatchQueue(label: "ni.mediacmd", qos: .userInitiated)   // serial: quick taps never run osascript in parallel
func sendMediaCommand(_ cmd: Int) {
    mediaCommandQueue.async {
        _ = runJXA("""
        ObjC.import("Foundation");
        $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
        $.NSClassFromString("MRNowPlayingController").localRouteController.sendCommandOptionsCompletion(\(cmd), $(), null);
        delay(0.2);
        "";
        """)
    }
}

/// Jumps the playing track to `seconds` (MediaRemote command 24, "seek to playback position").
func sendMediaSeek(_ seconds: Double) {
    mediaCommandQueue.async {
        _ = runJXA("""
        ObjC.import("Foundation");
        $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
        $.NSClassFromString("MRNowPlayingController").localRouteController.sendCommandOptionsCompletion(24, $({kMRMediaRemoteOptionPlaybackPosition: \(seconds)}), null);
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
    static func outputDevice() -> AudioObjectID? {
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

private let artworkScript = """
ObjC.import("Foundation");
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
var out = "";
var req = $.NSClassFromString("MRNowPlayingRequest");
if (req) {
  var item = req.localNowPlayingItem;
  if (item && !item.isNil()) {
    try {
      var d = item.nowPlayingInfo.objectForKey("kMRMediaRemoteNowPlayingInfoArtworkData");
      if (d && !d.isNil()) out = ObjC.unwrap(d.base64EncodedStringWithOptions(0));
    } catch (e) {}
  }
}
out;
"""

/// The cover art of whatever is playing, as the player itself hands it over (no store id needed).
func queryArtworkData() -> NSImage? {
    let s = runJXA(artworkScript)
    guard !s.isEmpty, let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return nil }
    return NSImage(data: d)
}

func fetchArtwork(storeID: String, completion: @escaping (NSImage?) -> Void) {
    let region = Locale.current.region?.identifier ?? "US"
    guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(storeID)&country=\(region)") else { completion(nil); return }
    var req = URLRequest(url: url); req.timeoutInterval = 8
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let data = data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = (j["results"] as? [[String: Any]])?.first,
              let u100 = r["artworkUrl100"] as? String,
              let imgURL = URL(string: u100.replacingOccurrences(of: "100x100bb", with: "300x300bb")) else { completion(nil); return }
        var r2 = URLRequest(url: imgURL); r2.timeoutInterval = 8
        URLSession.shared.dataTask(with: r2) { d2, _, _ in completion(d2.flatMap { NSImage(data: $0) }) }.resume()
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
    private weak var shown: NSImage?
    func setImage(_ img: NSImage?) {
        guard img !== shown else { return }                  // called every refresh: only react when the picture changes
        let first = shown == nil && layer?.contents == nil
        shown = img
        if !first {                                          // cross-fade to the new cover instead of cutting
            let t = CATransition(); t.type = .fade; t.duration = 0.4
            t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(t, forKey: "cover")
        }
        layer?.contents = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        note.isHidden = img != nil
    }
}

/// Real-time spectrum of whatever the Mac is playing: a global Core Audio process tap (macOS 14.2+; needs the
/// "system audio recording" permission, NOT screen recording) feeds a 1024-point FFT, folded into four bands.
final class AudioLevels {
    static let shared = AudioLevels()
    /// Written on the audio queue, read 30 times a second on the main thread: guarded, because an unsynchronised Swift array
    /// that is replaced while another thread reads it can hand out a torn buffer (that was the crash after hours of uptime).
    private let bandLock = NSLock()
    private var _bands = [Float](repeating: 0, count: 5)
    var bands: [Float] {
        get { bandLock.lock(); defer { bandLock.unlock() }; return _bands }
        set { bandLock.lock(); _bands = newValue; bandLock.unlock() }
    }
    private(set) var failed = false               // the tap could not be set up at all (permission missing / unsupported)
    private var watchdog: DispatchSourceTimer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private(set) var live = false                 // true once audio blocks actually arrive
    private var lastBlock = CFAbsoluteTimeGetCurrent() - 100
    private var tap = AudioObjectID(kAudioObjectUnknown), agg = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let n = 1024
    private var ring = [Float](repeating: 0, count: 1024), fill = 0, ringPos = 0     // ring: circular, oldest sample at ringPos
    private var ordered = [Float](repeating: 0, count: 1024)                      // scratch: the ring in time order
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)
    private var lastAnalysis = 0.0
    private var peaks = [Float](repeating: 0.0001, count: 5)
    private lazy var fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
    private let q = DispatchQueue(label: "ni.audio", qos: .userInteractive)
    private var nap: NSObjectProtocol?                  // keeps macOS from throttling the app (App Nap) while the island is collapsed
    private var users = 0
    private let debugAudio = ProcessInfo.processInfo.environment["NI_DEBUG"] != nil
    private var lastPrint = 0.0

    var fresh: Bool { CFAbsoluteTimeGetCurrent() - lastBlock < 1.0 }

    func retain() { q.async { self.users += 1; if self.users == 1 { self.begin() } } }
    func release() { q.async { self.users -= 1; if self.users == 0 { self.end() } } }

    /// The tap is tied to the output device it was built on: when the output changes (AirPods connect, a Bluetooth profile switch,
    /// the sample rate changes...) it goes silent. So rebuild it on every change, and whenever blocks stop arriving.
    private func begin() {
        start()
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restart() }
        outputListener = l
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, q, l)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: 1.0, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let s = self, s.users > 0, !s.failed, CFAbsoluteTimeGetCurrent() - s.lastBlock > 2.0, CFAbsoluteTimeGetCurrent() - s.startedAt > 2.0 else { return }
            s.restart()
        }
        t.resume(); watchdog = t
    }
    private func end() {
        watchdog?.cancel(); watchdog = nil
        if let l = outputListener {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, q, l); outputListener = nil
        }
        stop()
    }
    func debugStall() { q.async { if let p = self.proc { AudioDeviceStop(self.agg, p) } } }     // test hook: the tap silently dies
    private func restart() { guard users > 0 else { return }; stop(); start() }
    private var startedAt = CFAbsoluteTimeGetCurrent()

    private func start() {
        nap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "audio equalizer")
        guard #available(macOS 14.2, *), ProcessInfo.processInfo.environment["NI_NOAUDIO"] == nil else { return }
        startedAt = CFAbsoluteTimeGetCurrent(); lastBlock = startedAt
        failed = false
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID(); desc.muteBehavior = .unmuted; desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { failed = true; return }
        var outUID: String?
        var dev = AudioObjectID(kAudioObjectUnknown), sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr {
            var uid: Unmanaged<CFString>?; var s2 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var b = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(dev, &b, 0, nil, &s2, &uid) == noErr { outUID = uid?.takeRetainedValue() as String? }
        }
        var d: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchIsland tap",
            kAudioAggregateDeviceUIDKey: "com.kusbeoms.notchisland.tap.\(desc.uuid.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
        if let u = outUID { d[kAudioAggregateDeviceMainSubDeviceKey] = u; d[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: u]] }
        guard AudioHardwareCreateAggregateDevice(d as CFDictionary, &agg) == noErr else { stop(); failed = true; return }
        let st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, q) { [weak self] _, inData, _, _, _ in
            self?.consume(inData)
        }
        guard st == noErr, let p = proc, AudioDeviceStart(agg, p) == noErr else { stop(); failed = true; return }
    }

    private func stop() {
        if let n = nap { ProcessInfo.processInfo.endActivity(n); nap = nil }
        if let p = proc { AudioDeviceStop(agg, p); AudioDeviceDestroyIOProcID(agg, p); proc = nil }
        if agg != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(agg); agg = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
        bands = [0, 0, 0, 0, 0]; live = false; fill = 0; ringPos = 0
    }

    private func consume(_ list: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let b = abl.first, let raw = b.mData else { return }
        let ch = max(1, Int(b.mNumberChannels)), frames = Int(b.mDataByteSize) / (4 * ch)
        let x = raw.assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            var v: Float = 0
            for c in 0..<ch { v += x[i * ch + c] }
            ring[ringPos] = v / Float(ch); ringPos = (ringPos + 1) % n
        }
        fill = min(n, fill + frames)
        let now = CFAbsoluteTimeGetCurrent()
        lastBlock = now; live = true
        guard now - lastAnalysis >= 1.0 / 40 else { return }       // the bars only redraw at 30Hz: no need for a FFT per audio block
        lastAnalysis = now
        analyse()
    }

    private func analyse() {
        guard let fft else { return }
        var win = [Float](repeating: 0, count: n)
        ordered.replaceSubrange(0..<(n - ringPos), with: ring[ringPos...])
        ordered.replaceSubrange((n - ringPos)..<n, with: ring[..<ringPos])
        vDSP.multiply(ordered, window, result: &win)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var sp = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            win.withUnsafeBufferPointer { w in
                w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sp, 1, vDSP_Length(n / 2)) }
            }
            fft.forward(input: sp, output: &sp)
            vDSP.absolute(sp, result: &mags)
        } }
        let hz = Float(48000) / Float(n)                       // good enough: 44.1k/48k differ by under 9%
        let edges: [Float] = [40, 150, 500, 1600, 5000, 13000]
        var out = [Float](repeating: 0, count: 5)
        for k in 0..<5 {
            let lo = max(1, Int(edges[k] / hz)), hi = min(n / 2 - 1, Int(edges[k + 1] / hz))
            guard hi > lo else { continue }
            let e = vDSP.mean(Array(mags[lo...hi]))
            peaks[k] = max(e, peaks[k] * 0.995)                // slow auto-gain: lively at any volume
            out[k] = peaks[k] > 0.001 ? min(1, pow(e / peaks[k], 0.8)) : 0
        }
        bands = out
        if debugAudio, CFAbsoluteTimeGetCurrent() - lastPrint > 0.5 { lastPrint = CFAbsoluteTimeGetCurrent(); FileHandle.standardError.write("bands \(out)\n".data(using: .utf8)!) }
    }
}

/// Five bars that dance to the real audio (falls back to a canned loop when no audio can be tapped).
final class EqView: NSView {
    private var bars: [CALayer] = []
    private var animating = false, fake = false
    private var timer: Timer?, quietSince: CFAbsoluteTime?
    private var levels: [CGFloat] = [CGFloat](repeating: 0.3, count: 5)
    var color: NSColor = accent { didSet { bars.forEach { $0.backgroundColor = color.cgColor } } }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<5 {
            let l = CALayer()
            l.backgroundColor = color.cgColor
            l.cornerRadius = 1
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
            l.transform = CATransform3DMakeScale(1, 0.3, 1)
            layer?.addSublayer(l)
            bars.append(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let bw: CGFloat = 2.5, gap = (bounds.width - bw * 5) / 4
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in bars.enumerated() {
            l.bounds = CGRect(x: 0, y: 0, width: bw, height: bounds.height)
            l.position = CGPoint(x: bw / 2 + CGFloat(i) * (bw + gap), y: 0)
        }
        CATransaction.commit()
    }
    deinit { if animating { AudioLevels.shared.release() }; timer?.invalidate() }

    func setPlaying(_ p: Bool) {
        if p == animating { return }
        dlog("EQ \(ObjectIdentifier(self).hashValue % 9973) setPlaying(\(p))")
        animating = p
        if p {
            AudioLevels.shared.retain()
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.01
            RunLoop.main.add(t, forMode: .common); timer = t
        } else {
            AudioLevels.shared.release()
            timer?.invalidate(); timer = nil
            setFake(false)
            glide(to: [CGFloat](repeating: 0.3, count: 5), rate: 0.25)
        }
    }

    private func tick() {
        guard animating else { return }
        let a = AudioLevels.shared
        if a.fresh {
            setFake(false)
            glide(to: a.bands.map { 0.18 + 0.82 * CGFloat($0) }, rate: 0.55)
            quietSince = nil
        } else {
            let now = CFAbsoluteTimeGetCurrent()
            if quietSince == nil { quietSince = now }
            if a.failed, now - quietSince! > 1.0 { setFake(true) }
            else if !a.failed { glide(to: [CGFloat](repeating: 0.18, count: 5), rate: 0.3) }     // restarting the tap: rest, never a canned loop       // still no audio tap after a while (permission missing / unsupported): canned bounce
        }
    }

    /// Eases the bars to `target`; fast on the way up and slower on the way down, like a real meter.
    private func glide(to target: [CGFloat], rate: CGFloat) {
        guard target.count >= bars.count, levels.count >= bars.count else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in 0..<5 {
            let up = target[i] > levels[i]
            levels[i] += (target[i] - levels[i]) * (up ? rate : rate * 0.45)
            bars[i].transform = CATransform3DMakeScale(1, max(0.12, min(1, levels[i])), 1)
        }
        CATransaction.commit()
    }

    private func setFake(_ on: Bool) {
        guard on != fake else { return }
        fake = on
        dlog("EQ \(ObjectIdentifier(self).hashValue % 9973) setFake(\(on))")
        for (i, l) in bars.enumerated() {
            l.removeAllAnimations()
            guard on else { continue }
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = 0.3; a.toValue = 1.0
            a.duration = 0.42 + Double(i) * 0.11
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.timeOffset = Double(i) * 0.13
            l.add(a, forKey: "eq")
        }
    }
}

final class ProgressBar: NSView {
    private let track = CALayer(), fill = CALayer()
    private static let lineH: CGFloat = 4
    /// Called while the pointer scrubs (final == false) and when it lets go (final == true), with the position 0...1.
    var onScrub: ((CGFloat, Bool) -> Void)?
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
        track.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        track.cornerRadius = ProgressBar.lineH / 2
        fill.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
        fill.cornerRadius = ProgressBar.lineH / 2
        layer?.addSublayer(track); layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); relayout() }
    private func relayout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let y = (bounds.height - ProgressBar.lineH) / 2
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: ProgressBar.lineH)
        fill.frame = CGRect(x: 0, y: y, width: bounds.width * min(max(fraction, 0), 1), height: ProgressBar.lineH)
        CATransaction.commit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func scrub(_ e: NSEvent, final: Bool) {
        let f = min(max(convert(e.locationInWindow, from: nil).x / max(bounds.width, 1), 0), 1)
        fraction = f
        onScrub?(f, final)
    }
    override func mouseDown(with event: NSEvent) { scrub(event, final: false) }
    override func mouseDragged(with event: NSEvent) { scrub(event, final: false) }
    override func mouseUp(with event: NSEvent) { scrub(event, final: true) }
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

/// The timer's icon: a ring with a small glyph inside. A stopwatch's ring fills up (one lap per minute); a countdown's ring
/// shrinks as the time runs out.
final class TimerRing: NSView {
    private let track = CAShapeLayer(), prog = CAShapeLayer()
    private let glyph = NSImageView()
    private var glyphName = ""
    var fraction: CGFloat = 0 {
        didSet {
            guard abs(fraction - oldValue) > 0.0005 else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)       // no easing: a lap wraps around instantly
            prog.strokeEnd = min(max(fraction, 0), 1)
            CATransaction.commit()
        }
    }
    var countdown = false {
        didSet {
            let name = countdown ? "hourglass" : "stopwatch"
            guard name != glyphName else { return }
            glyphName = name
            glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        }
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for l in [track, prog] { l.fillColor = nil; l.lineWidth = 2.4; l.lineCap = .round; layer?.addSublayer(l) }
        track.strokeColor = accent.withAlphaComponent(0.25).cgColor
        prog.strokeColor = accent.cgColor
        prog.strokeEnd = 0
        glyph.contentTintColor = accent
        addSubview(glyph)
        countdown = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: min(bounds.width, bounds.height) / 2 - 2.2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)      // from the top, clockwise
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [track, prog] { l.frame = bounds; l.path = path }
        CATransaction.commit()
        glyph.frame = bounds
    }
}

/// A wheel seen edge-on under the island. There is an invisible circle with its centre inside the island; the ticks stand on
/// its rim and point outwards. The rim bulges out below the island in the middle and tucks back in behind the island at both
/// ends, so the dial looks wrapped onto the island. (This view sits behind the island's black body, which hides the ends.)
/// One long tick per live activity; the wheel goes round without an end, so the activities repeat on it.
final class DialView: NSView {
    static let perMajor = 6                                  // minor ticks between two activities
    static let gap: CGFloat = 11                             // distance between ticks along the rim
    static let radius: CGFloat = 230                         // radius of the invisible circle
    static let bulge: CGFloat = 38                           // how far the rim hangs below the island's bottom edge
    struct Geometry { var body = NSRect.zero }
    var geometry = Geometry() { didSet { relayout() } }
    private var ticks: [CALayer] = []
    var count = 1 { didSet { if count != oldValue { relayout() } } }
    private(set) var position: CGFloat = 0                   // in activities: 0 = the first, 1 = the second...
    private var target: CGFloat = 0
    private var velocity: CGFloat = 0
    private var timer: Timer?
    /// Light mode: dark ticks. Dark mode: light ticks. (Each tick also has an outline of the opposite colour, so it reads on
    /// any background without the screen having to be looked at.)
    var lightAppearance = false { didSet { if lightAppearance != oldValue { relayout() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<60 {
            let l = CALayer()
            l.borderWidth = 1
            l.cornerRadius = 2.2
            l.shadowColor = NSColor.black.cgColor; l.shadowOpacity = 0.3; l.shadowRadius = 2; l.shadowOffset = .zero
            l.bounds = CGRect(x: 0, y: 0, width: 4.4, height: 14)
            layer?.addSublayer(l); ticks.append(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); relayout() }

    /// Click and drag on the ticks turns the wheel: (pointer movement in points, phase 0 = down, 1 = move, 2 = up).
    var onDrag: ((CGFloat, Int) -> Void)?
    override func hitTest(_ p: NSPoint) -> NSView? {
        let b = geometry.body
        guard alphaValue > 0.3, !isHidden, p.y < b.minY + 2, p.y > b.minY - DialView.bulge - 14,
              p.x > b.minX - 24, p.x < b.maxX + 24 else { return nil }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var lastX: CGFloat = 0
    override func mouseDown(with event: NSEvent) { lastX = event.locationInWindow.x; onDrag?(0, 0) }
    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX, 1); lastX = x
    }
    override func mouseUp(with event: NSEvent) { onDrag?(0, 2) }

    /// Moves the wheel to `t` (in activities). A finger turning it sets it directly; otherwise it springs there.
    func set(_ t: CGFloat, animated: Bool) {
        target = t
        if !animated { position = t; velocity = 0; timer?.invalidate(); timer = nil; relayout(); return }
        guard timer == nil, abs(position - target) > 0.0008 || abs(velocity) > 0.01 else { return }
        let dt: CGFloat = 1.0 / 60
        let tm = Timer(timeInterval: Double(dt), repeats: true) { [weak self] tm in
            guard let s = self else { tm.invalidate(); return }
            s.velocity += (-230 * (s.position - s.target) - 25 * s.velocity) * dt        // a soft spring, a touch of overshoot
            s.position += s.velocity * dt
            if abs(s.position - s.target) < 0.0008 && abs(s.velocity) < 0.01 { s.position = s.target; s.velocity = 0; tm.invalidate(); s.timer = nil }
            s.relayout()
        }
        RunLoop.main.add(tm, forMode: .common); timer = tm
    }

    private func relayout() {
        let body = geometry.body
        guard body.width > 0 else { return }
        let R = DialView.radius, g = DialView.bulge
        let c = CGPoint(x: body.midX, y: body.minY + (R - g))             // the circle's centre, inside the island
        let thetaMax = acos(1 - g / R)                                      // where the rim comes back up to the island's bottom edge
        let gap = DialView.gap, per = DialView.perMajor
        let unit = CGFloat(per) * gap
        let first = Int(floor((position * unit - R * thetaMax) / gap)) - 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in ticks.enumerated() {
            let k = first + i
            let th = (CGFloat(k) * gap - position * unit) / R               // angle from straight down; ticks are spaced evenly on the rim
            guard abs(th) < thetaMax else { l.isHidden = true; continue }
            let n = CGPoint(x: sin(th), y: -cos(th))                        // outwards from the centre
            let edge = abs(th) / thetaMax                                   // 0 in the middle ... 1 where it tucks in
            let major = ((k % per) + per) % per == 0                        // the wheel goes round: the activities repeat on it
            let selected = major && abs(CGFloat(k / per) - position) < 0.5
            let len = (major ? 22 : 12) * (1 - 0.3 * edge)
            let mid = R - 3 + len / 2                                       // a tick starts just inside the rim and points outwards
            l.backgroundColor = NSColor(white: lightAppearance ? 0.1 : 1, alpha: 1).cgColor
            l.borderColor = NSColor(white: lightAppearance ? 1 : 0, alpha: 0.85).cgColor
            l.isHidden = false
            l.bounds = CGRect(x: 0, y: 0, width: 4.4, height: len + 2)
            l.position = CGPoint(x: c.x + n.x * mid, y: c.y + n.y * mid)
            l.transform = CATransform3DMakeRotation(atan2(n.y, n.x) + .pi / 2, 0, 0, 1)
            l.opacity = Float(pow(cos(edge * .pi / 2), 0.8) * (major ? (selected ? 1 : 0.7) : 0.5))
        }
        CATransaction.commit()
    }
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

/// A view that can pick up a file and drag it out. The file under the pointer is decided by `fileForDrag`; once the drop
/// has been accepted somewhere else, `onDragFinished` is told (the file then leaves the pocket).
class FileDragView: NSView, NSDraggingSource {
    var fileForDrag: ((NSEvent) -> URL?)?
    var onDragBegan: (() -> Void)?
    var onDragFinished: ((URL, Bool) -> Void)?
    var downPoint: NSPoint?
    private var draggingURL: URL?

    override func mouseDragged(with event: NSEvent) {
        guard draggingURL == nil, let d = downPoint, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 4,
              let u = fileForDrag?(event) else { return }
        downPoint = nil; draggingURL = u
        onDragBegan?()
        let item = NSDraggingItem(pasteboardWriter: u as NSURL)
        let img = NSWorkspace.shared.icon(forFile: u.path)
        img.size = NSSize(width: 48, height: 48)
        let at = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: at.x - 24, y: at.y - 24, width: 48, height: 48), contents: img)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let u = draggingURL { onDragFinished?(u, !operation.isEmpty) }
        draggingURL = nil
    }
}

enum Body { case none, hud, banner, alert, media, timer, file, drop }
enum LevelKind { case volume, brightness }

/// Everything that can be a live activity, in the order they are listed when several run at once.
enum ActKind: Hashable { case media, timer, charging, lowBattery, airpods, file(URL) }     // every file in the pocket is an activity
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

/// A soft shadow behind an island: a bigger, click-through window that draws the island's own shape with a blurred shadow.
/// (The system window shadow draws a light hairline around the shape, which does not suit something that merges with the notch.)
final class ShadowView: NSView {
    static let pad: CGFloat = 36                                  // room around the island for the blur
    var pathProvider: ((CGSize) -> CGPath)?
    private let shape = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = NSColor.black.cgColor
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0.4
        shape.shadowRadius = 12
        shape.shadowOffset = CGSize(width: 0, height: -5)       // falls a little downwards
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let pad = ShadowView.pad
        let size = CGSize(width: max(bounds.width - 2 * pad, 1), height: max(bounds.height - 2 * pad, 1))
        let path = pathProvider?(size) ?? CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var move = CGAffineTransform(translationX: pad, y: pad)
        let placed = path.copy(using: &move) ?? path
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = placed
        shape.shadowPath = placed
        CATransaction.commit()
    }
}

/// A window (the island itself, the detached icon, the pill under the notch) and the springs that move it.
final class Piece {
    let panel: NSPanel
    var shadow: NSPanel?
    var x = SpringV(), w = SpringV(), h = SpringV(), ty = SpringV()    // left edge, width, height, distance from the top of the screen
    var m = SpringV()                                                  // extra room under the island (for the dial)
    var fullW: CGFloat = 1
    var active = false      // wants to be on screen
    var visible = false     // is on screen (an inactive piece stays until it has shrunk away)
    init(panel: NSPanel) { self.panel = panel }
    var settled: Bool { x.settled && w.settled && h.settled && ty.settled && m.settled }
    func snap() { x.snap(); w.snap(); h.snap(); ty.snap(); m.snap() }
}

/// The detached icon circle and the pill under the notch: black capsules holding slot views, centred.
final class PillView: FileDragView {
    var onPress: (() -> Void)?
    var onRelease: ((Bool) -> Void)?
    var items: [SlotItem] = [] { didSet { needsLayout = true } }
    var withDetail = false { didSet { needsLayout = true } }
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
        shapeMask.path = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()
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
    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow; onPress?() }
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
    var bannerSymbol = ""
    var fileShown: URL?
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
    // file body: the file's icon, name and where it lives; buttons to show it in Finder / let it go
    let fIcon = NSImageView()
    let fName = makeLabel(15, .semibold, .white)
    let fSub = makeLabel(12, .regular, NSColor(white: 1, alpha: 0.55))
    let fRevealB = makeSymbolButton("magnifyingglass", 15, .white)
    let fRemoveB = makeSymbolButton("xmark", 14, .white)
    // drop body: shown while a file is being dragged towards the notch
    let dropIcon = NSImageView()
    let dropHint = makeLabel(14, .medium, NSColor(white: 1, alpha: 0.75))

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in [pauseB, cancelB] { b.wantsLayer = true; b.layer?.cornerRadius = 22 }
        pauseB.layer?.backgroundColor = accent.withAlphaComponent(0.28).cgColor
        cancelB.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        hIcon.contentTintColor = .white
        dropIcon.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 26, weight: .semibold))
        dropIcon.contentTintColor = NSColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1)
        dropHint.stringValue = "여기에 놓으세요"
        fIcon.imageScaling = .scaleProportionallyUpOrDown
        for v in all { addSubview(v); v.alphaValue = 0 }
    }
    required init?(coder: NSCoder) { fatalError() }

    var all: [NSView] {
        [art, titleL, artistL, bodyEq, progress, elapsedL, remainL,
         prevB, playB, nextB, pauseB, cancelB, tLabel, tTime, alertL, bTitle, bPct, bGlyph, bAir, bRing, hIcon, hBar]
            + [fIcon, fName, fSub, fRevealB, fRemoveB, dropIcon, dropHint]
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
        progress.frame = NSRect(x: pad, y: top + 50, width: w - 2 * pad, height: 16)      // a taller hit area around the 4pt line
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
        bAir.frame = NSRect(x: 6, y: (notchH - 26) / 2, width: 28, height: 26)
        bGlyph.frame = NSRect(x: w - 14 - 34, y: (notchH - 15) / 2, width: 34, height: 15)
        bPct.frame = NSRect(x: w - 14 - 34 - 8 - 56, y: (notchH - 20) / 2, width: 56, height: 20)
        bRing.frame = NSRect(x: w - 6 - 26, y: (notchH - 26) / 2, width: 26, height: 26)
        // HUD
        hIcon.frame = NSRect(x: pad, y: top + 6, width: 24, height: 24)          // below the notch, icon on the left
        hBar.frame = NSRect(x: pad + 24 + 14, y: top + 7, width: max(0, w - pad - 24 - 14 - pad), height: 22)
        // alert
        alertL.frame = NSRect(x: pad, y: notchH + 6, width: w - 2 * pad, height: 22)
        // file
        fIcon.frame = NSRect(x: pad, y: top, width: 48, height: 48)
        let fx = pad + 48 + 12, fw = max(0, w - fx - pad - 76)
        fName.frame = NSRect(x: fx, y: top + 4, width: fw, height: 20)
        fSub.frame = NSRect(x: fx, y: top + 25, width: fw, height: 16)
        fRevealB.frame = NSRect(x: w - pad - 72, y: top + 8, width: 34, height: 32)
        fRemoveB.frame = NSRect(x: w - pad - 36, y: top + 8, width: 34, height: 32)
        // drop hint
        dropIcon.frame = NSRect(x: pad, y: top + 6, width: 36, height: 36)
        dropHint.frame = NSRect(x: pad + 46, y: top + 14, width: max(0, w - pad * 2 - 46), height: 20)
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
            (fIcon, expanded && b == .file), (fName, expanded && b == .file), (fSub, expanded && b == .file),
            (fRevealB, expanded && b == .file), (fRemoveB, expanded && b == .file),
            (dropIcon, expanded && b == .drop), (dropHint, expanded && b == .drop),
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

final class IslandView: FileDragView {
    var onPress: (() -> Void)?
    var onRelease: ((Bool) -> Void)?       // true when the finger came up inside the island
    let content = Content(frame: .zero)
    let dial = DialView()                  // drawn outside the black body, round its lower edge
    private let body = NSView()            // the black island itself (masked to the notch shape); `content` lives in it
    private let shapeMask = CAShapeLayer()
    var earLeft = true { didSet { if earLeft != oldValue { needsLayout = true } } }
    var earRight = true { didSet { if earRight != oldValue { needsLayout = true } } }   // false: the right edge is flush with the notch
    /// Room under the island (the window is taller than the island by this much) for the dial's ticks.
    var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { needsLayout = true } } }
    var bodyRect: NSRect { NSRect(x: 0, y: bottomInset, width: bounds.width, height: max(bounds.height - bottomInset, 0)) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor.black.cgColor
        body.layer?.mask = shapeMask
        content.frame = bounds
        content.autoresizingMask = []                     // laid out by hand: it sits between the ears
        body.addSubview(content)
        dial.alphaValue = 0
        addSubview(dial)                                  // behind the island: the ends of the dial tuck in behind the black body
        addSubview(body)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        body.frame = bodyRect
        let w = body.bounds.width, h = body.bounds.height
        let t = earRadius(h)
        let l = earLeft ? t : 0, r = earRight ? t : 0
        content.frame = NSRect(x: l, y: 0, width: max(0, w - l - r), height: h)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shapeMask.frame = body.bounds
        shapeMask.path = notchPath(w, h, earL: earLeft, earR: earRight)
        CATransaction.commit()
        dial.frame = bounds
        dial.geometry = DialView.Geometry(body: bodyRect)
    }

    var onOpenSource: (() -> Void)?
    private var sourceTapActive = false
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }

    // Files dragged onto the island (from Finder...) go into the shelf.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dlog("draggingEntered src=\(String(describing: sender.draggingSource)) frame=\(window?.frame ?? .zero)")
        if sender.draggingSource is FileDragView { return [] }        // our own file dragged back onto the island: ignore
        onDragEnter?(); return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { sender.draggingSource is FileDragView ? [] : .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragExit?() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dlog("performDragOperation")
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDragExit?()
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    /// Only controls that are actually visible can take a click. (Hidden-by-alpha controls stacked on top of a
    /// visible one used to swallow its clicks.) Everything else is a press on the island itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return nil }
        let here = convert(point, from: sv)
        let strip = NSRect(x: 0, y: 0, width: bounds.width, height: bottomInset + 6)      // the dial, just under the island
        guard bodyRect.contains(here) || (bottomInset > 0 && strip.contains(here)) else { return nil }
        guard bodyRect.contains(here) else { return dial.hitTest(here) ?? self }
        let p = content.convert(here, from: self)
        for v in content.subviews.reversed() where (v is NSButton || v is LevelBar || v is ProgressBar) && !v.isHidden && v.alphaValue > 0.3 {
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
        guard bodyRect.contains(convert(event.locationInWindow, from: nil)) else { return }       // the dial is for scrolling only
        downPoint = event.locationInWindow
        sourceTapActive = overSource(event)
        if !sourceTapActive { onPress?() }
    }
    override func mouseUp(with event: NSEvent) {
        if sourceTapActive {
            sourceTapActive = false
            if overSource(event) { onOpenSource?() }
            return
        }
        onRelease?(bodyRect.contains(convert(event.locationInWindow, from: nil)))
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
    var mainP: Piece!, pillP: Piece!
    var pillView: PillView!
    var stiffness: CGFloat = 400, damping: CGFloat = 30     // the island's own spring (changes with the shape)
    var signalSources: [DispatchSourceSignal] = []
    var simLux: Double?
    var atRest = true                      // spring has settled
    var popUntil = Date.distantPast       // brief swell-and-return when there is nothing to show

    var panel: NSPanel!
    var view: IslandView!
    var c: Content { view.content }
    static func pickScreen() -> NSScreen { NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0] }
    var screen: NSScreen = App.pickScreen()
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
    var chargeShownUntil = Date.distantPast       // the charging activity shows for 3s after the charger is connected, then goes
    var actOrder: [ActKind] = []
    var selected: ActKind?                     // which activity the expanded card shows
    var pressKind: ActKind?
    var airList: [AirPodsInfo] = []
    var bannerHideAt: Date?
    // the pocket: every file dropped on the notch is an activity of its own (paths only, nothing is copied)
    var files: [URL] = []
    var fileShown: URL?
    var fileInfo: [URL: String] = [:]
    var dragEntered = false, dragNear = false, dragActive = false, wasBtn = false, downChange = 0
    var dropping: Bool { dragEntered || dragNear }        // a file drag is over / close to the island
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
    var fullSince: Date?
    var ambient = -1.0               // slow average of the light while uncovered: the touch threshold follows it
    var nothingPolls = 0             // consecutive 'nothing is playing' answers
    var idleRefreshed = false
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
        case .charging:   return demoActsN != nil ? demoKinds.contains(k) : (battery?.plugged == true && battery?.charging == true && Date() < chargeShownUntil)   // only the first 3s after plugging in
        case .lowBattery: return demoActsN != nil ? demoKinds.contains(k) : (battery?.plugged == false && (battery?.level ?? 100) <= 20)
        case .airpods:    return demoActsN != nil && demoKinds.contains(k)       // real AirPods only show a banner when they connect
        case .file(let u): return files.contains(u)
        }
    }

    /// Keeps `actOrder` = the running activities in the order they started.
    func syncActivities() {
        for k in allKinds {
            let on = isActive(k), has = actOrder.contains(k)
            if on && !has { actOrder.append(k) } else if !on && has { actOrder.removeAll { $0 == k } }
        }
        for u in files where !actOrder.contains(.file(u)) { actOrder.append(.file(u)) }
        func gone(_ k: ActKind) -> Bool { if case .file(let u) = k { return !files.contains(u) }; return false }
        actOrder.removeAll(where: gone)
        // more than five activities: the oldest are not shown, and a file that falls off is discarded
        if actOrder.count > 5 {
            for k in actOrder.dropLast(5) { if case .file(let u) = k { files.removeAll { $0 == u }; slotItems.removeValue(forKey: k) } }
            actOrder.removeAll(where: gone)
            fileSave()
        }
    }
    var acts: [ActKind] { Array(actOrder.suffix(5)) }

    func bodyFor(_ k: ActKind) -> Body {
        switch k {
        case .media: return .media
        case .timer: return .timer
        case .charging, .lowBattery, .airpods: return .banner
        case .file: return .file
        }
    }

    /// The dial is shown along the bottom of an open activity card when there is more than one activity to choose from.
    var dialShown: Bool { !hudActive && !dropping && banner == nil && alertText == nil && acts.count >= 2 && cardKind != nil }
    var dialMargin: CGFloat { (shape == .expanded && dialShown) ? 62 : 0 }       // room under the island for the dial's ticks
    var dialWasOn = false
    var scrollHolding: Bool { dialShown && shape == .expanded && Date().timeIntervalSince(lastScrollAt) < 1.0 }
    var holdH: CGFloat = 0                              // while scrolling the card never gets lower, so the pointer stays on the dial
    var lastScrollAt = Date.distantPast
    var dialPos: CGFloat = 0                            // where the fingers have turned the wheel, in activities (continuous)
    var dialLastTick = 0
    var lastDialHaptic = Date.distantPast
    var dialSettle: Timer?

    /// Two fingers sideways over the dial turn the wheel: it follows the fingers (and keeps going when they flick it), every tick
    /// is a little magnet, the long ticks (the running activities) also tap the trackpad, and when it stops it settles on the
    /// nearest activity.
    func handleScroll(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }   // sideways swipes only
        let finger = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX     // fingers moving left < 0
        if hudActive {                                                       // volume / brightness HUD: sideways = the slider
            hudDragged(min(1, max(0, hudValue + Float(finger) / 400)))
            return
        }
        guard shape == .expanded else { return }
        guard dialShown, e.locationInWindow.y < view.bottomInset + 66 else {           // on the card itself
            if cardKind == .media, let m = media, m.duration > 0 { scrubBy(finger / 450, m) }
            return
        }
        let now = Date()
        let fresh = e.phase == .began || e.phase == .mayBegin || now.timeIntervalSince(lastScrollAt) > 0.3
        if fresh { dialPos = view.dial.position; dialLastTick = Int((dialPos * CGFloat(DialView.perMajor)).rounded()) }
        lastScrollAt = now
        holdH = max(holdH, mainP.h.cur, mainP.h.tgt)
        let unit = DialView.gap * CGFloat(DialView.perMajor)
        dialPos -= finger / (unit * 1.9)                                                       // fingers left: on to the next (and round again); a gentle ratio
        turnDial()
        dialSettle?.invalidate()
        let t = Timer(timeInterval: 0.14, repeats: false) { [weak self] _ in self?.settleDial() }   // no more events (or momentum): settle
        RunLoop.main.add(t, forMode: .common); dialSettle = t
    }

    /// Click and drag on the dial's ticks: the ticks follow the pointer one to one.
    func dialDragged(_ dx: CGFloat, _ phase: Int) {
        guard shape == .expanded, dialShown else { return }
        lastScrollAt = Date()
        switch phase {
        case 0:
            dialSettle?.invalidate()
            dialPos = view.dial.position; dialLastTick = Int((dialPos * CGFloat(DialView.perMajor)).rounded())
            holdH = max(holdH, mainP.h.cur, mainP.h.tgt)
        case 1:
            dialPos -= dx / (DialView.gap * CGFloat(DialView.perMajor))
            turnDial()
        default:
            settleDial()
        }
    }

    // MARK: seeking (progress bar drag, or sideways scrolling on the music card)
    var seekFraction: CGFloat?                  // where the user has put the playhead, until it is committed
    var seekHoldUntil = Date.distantPast        // right after a seek the poll still reports the old position: ignore it
    var seekTimer: Timer?

    func scrubBy(_ d: CGFloat, _ m: Media) {
        let base = seekFraction ?? CGFloat(m.elapsedNow / m.duration)
        seekFraction = min(1, max(0, base + d))
        refreshUI()
        seekTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in self?.commitSeek() }
        RunLoop.main.add(t, forMode: .common); seekTimer = t
    }

    func scrubbed(_ f: CGFloat, final: Bool) {
        seekTimer?.invalidate()
        seekFraction = f
        if final { commitSeek() } else { refreshUI() }
    }

    func commitSeek() {
        seekTimer?.invalidate()
        guard let f = seekFraction, var m = media, m.duration > 0 else { seekFraction = nil; return }
        let pos = Double(f) * m.duration
        sendMediaSeek(pos)
        m.elapsed = pos; m.readAt = Date(); media = m
        seekFraction = nil
        seekHoldUntil = Date().addingTimeInterval(1.5)
        refreshUI()
    }

    /// Shows the wheel where the fingers have it, pulled towards the nearest tick like a detent, and follows it with the card.
    func turnDial() {
        let per = CGFloat(DialView.perMajor)
        let t = dialPos * per
        let n = t.rounded(), f = t - n
        let pulled = n + (f < 0 ? -1 : 1) * 0.5 * pow(min(2 * abs(f), 1), 2.0)       // it dwells on a tick, then slips to the next
        view.dial.set(pulled / per, animated: false)
        let tick = Int(n), perI = DialView.perMajor
        if tick != dialLastTick {
            // the little magnets on the ordinary ticks are silent; a tap on the trackpad only when the wheel catches on one of the
            // long ticks, i.e. on a running activity (also when a quick turn skips past several ticks in one go)
            let lo = min(tick, dialLastTick), hi = max(tick, dialLastTick)
            let caught = (lo...hi).contains { $0 % perI == 0 && $0 != dialLastTick }
            dialLastTick = tick
            if caught, Date().timeIntervalSince(lastDialHaptic) > 0.03 {
                lastDialHaptic = Date()
                haptic(.levelChange)
            }
        }
        let a = acts
        guard !a.isEmpty else { return }
        let idx = ((Int(dialPos.rounded()) % a.count) + a.count) % a.count          // endless: past the last comes the first
        if a[idx] != cardKind { selected = a[idx] }
    }

    func settleDial() {
        guard shape == .expanded, dialShown, !acts.isEmpty else { return }
        let r = dialPos.rounded()
        let idx = ((Int(r) % acts.count) + acts.count) % acts.count
        dialPos = r
        selected = acts[idx]
        view.dial.set(r, animated: true)
    }

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
        if dropping { return .drop }
        if banner != nil { return .banner }
        if alertText != nil { return .alert }
        switch cardKind {
        case .media?: return .media
        case .timer?: return .timer
        case .file(_)?: return .file
        case .charging?, .lowBattery?, .airpods?: return .banner
        case nil: return .none
        }
    }
    var hudActive: Bool { Date() < hudUntil }
    var liveActivity: Bool { hudActive || banner != nil || alertText != nil || !acts.isEmpty }
    let iconWing: CGFloat = 46                                       // space beside the notch for one icon
    /// Space beside the notch when a single activity shows its icon on the left and its detail on the right.
    func wingWidth(_ k: ActKind) -> CGFloat {
        switch k { case .timer: return 66; case .charging: return 58; case .lowBattery: return 62; case .airpods: return 44; default: return 50 }
    }
    /// Charging and low battery show their percentage (not an icon) in the narrow slots beside the notch.
    func showsPercent(_ k: ActKind) -> Bool { k == .charging || k == .lowBattery }
    func slotView(_ k: ActKind) -> (view: NSView, size: CGSize) {
        guard let it = slotItem(k) else { return (NSView(), .zero) }
        return showsPercent(k) ? (it.detail, it.detailSize) : (it.icon, CGSize(width: 24, height: 24))
    }
    func slotWing(_ k: ActKind) -> CGFloat { showsPercent(k) ? 58 : iconWing }     // room beside the notch for that slot
    var bannerWing: CGFloat { if case .airpods? = displayBanner { return 42 }; return 110 }       // AirPods: just the icon and the ring
    var expandedExtra: CGFloat { expandedExtraFor(body) }
    func expandedExtraFor(_ b: Body) -> CGFloat {
        switch b {
        case .media:  return 122
        case .file, .drop: return 62
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
        var pill: [ActKind] = []        // the pill under the notch (3...5 activities)
    }

    func makePlan() -> Plan {
        let a = acts
        if shape == .expanded {
            // an expanded card keeps the other activities as small icons beside the notch
            // only the tall cards have room beside the notch; one-line banners (charging, AirPods...) fill the whole band
            guard !hudActive, banner == nil, alertText == nil, let ck = cardKind, body == .media || body == .timer || body == .file else { return Plan() }
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
        default: return Plan(left: a[0], right: a[1], pill: Array(a.dropFirst(2)))
        }
    }

    // MARK: geometry (screen coordinates, y up)

    var notchLeft: CGFloat { screen.frame.midX - notchW / 2 }
    var notchRight: CGFloat { screen.frame.midX + notchW / 2 }
    /// Height of the compact island. Charging on its own stays within the menu bar (no taller than the notch).
    var compactH: CGFloat { (acts.count == 1 && acts[0] == .charging) ? notchH : notchH + 8 }

    func frame(for s: Shape) -> NSRect {
        let a = acts, n = a.count
        let mid = screen.frame.midX, top = screen.frame.maxY
        func r(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: top - h, width: w, height: h) }
        func compact(extra: CGFloat, h: CGFloat) -> NSRect {
            switch n {
            case 0: let w = notchW + extra; return r(mid - w / 2, w, h)
            case 1: let w = notchW + 2 * wingWidth(a[0]) + extra; return r(mid - w / 2, w, h)
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

    let pillH: CGFloat = 34, pillGap: CGFloat = 6
    /// The pill under the notch (3...5 activities): returns its rect and its distance from the top of the screen.
    func pillRect() -> (NSRect, CGFloat)? {
        guard shape != .expanded, acts.count >= 3 else { return nil }
        let items = acts.dropFirst(2).compactMap { slotItem($0) }
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
        panel.contentView = view
        panel.orderFrontRegardless()
        makeSticky(panel)
        let r0 = frame(for: .collapsed)
        mainP = Piece(panel: panel); mainP.active = true; mainP.visible = true
        mainP.x.jump(r0.minX); mainP.w.jump(r0.width); mainP.h.jump(r0.height)
        pillView = PillView(frame: .zero); pillView.withDetail = true
        let pillPanel = makePanel(.zero)
        pillPanel.contentView = pillView
        pillP = Piece(panel: pillPanel)
        pillView.onPress = { [weak self] in self?.pressBegan() }
        pillView.onRelease = { [weak self] inside in self?.pressEnded(inside: inside) }
        wire(c.prevB, #selector(prevTapped)); wire(c.playB, #selector(playPauseTapped)); wire(c.nextB, #selector(nextTapped))
        wire(c.pauseB, #selector(timerToggleTapped)); wire(c.cancelB, #selector(timerCancelTapped))
        attachShadow(to: mainP) { [weak self] size in
            notchPath(size.width, size.height, earL: self?.view.earLeft ?? true, earR: self?.view.earRight ?? true)
        }
        attachShadow(to: pillP) { size in CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil) }
        mainP.shadow?.orderFrontRegardless(); mainP.shadow.map { makeSticky($0) }
        makeSlotItems()
        link = screen.displayLink(target: self, selector: #selector(animTick(_:)))
        link?.add(to: .main, forMode: .common)
        link?.isPaused = true

        if let t = demoAlert { showAlert(t) }
        if demoTimer { timer.toggle(); pinned = true }
        if demoCharging { showBanner(.battery(title: "충전 중", level: 55, color: bannerGreen)) }
        if demoAirpods { showBanner(.airpods(symbol: "airpodspro", level: 80), autoHide: ProcessInfo.processInfo.environment["NI_AUTOHIDE"] != nil ? 4 : nil) }
        if let n = demoActsN {                                         // --demo-acts N: N fake activities, none pinned open
            if let pick = demoPick {
                if pick.contains("media") { media = Media(title: "승리를 위하여", artist: "트랜스픽션", playing: true, duration: 208, elapsed: 29, readAt: Date(), storeID: "") }
                if pick.contains("timer") { startDemoTimer() }
                prevTimerStarted = timer.started
                for (name, k) in [("charging", ActKind.charging), ("airpods", .airpods), ("lowBattery", .lowBattery)] where pick.contains(name) { demoKinds.insert(k) }
            } else {
            if n >= 1 { media = Media(title: "승리를 위하여", artist: "트랜스픽션", playing: true, duration: 208, elapsed: 29, readAt: Date(), storeID: "") }
            if n >= 2 { startDemoTimer() }
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
            signal(SIGHUP, SIG_IGN)
            let stallSrc = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)     // SIGHUP = kill the audio tap silently (test hook)
            stallSrc.setEventHandler { AudioLevels.shared.debugStall() }
            stallSrc.resume(); signalSources.append(stallSrc)
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
        fileLoad()
        view.onDragEnter = { [weak self] in self?.dragEntered = true }
        view.onDragExit = { [weak self] in self?.dragEntered = false }
        let dropped: ([URL]) -> Void = { [weak self] urls in
            guard let s = self else { return }
            s.fileAdd(urls)
            if let last = urls.last(where: { s.files.contains($0) }) { s.selected = .file(last) }   // the new file activity appears quietly
        }
        view.onDrop = dropped
        view.onScroll = { [weak self] e in self?.handleScroll(e) }
        for v in [view as FileDragView, pillView as FileDragView] {   // dragging a file out of the island
            v.fileForDrag = { [weak self] e in self?.fileForDrag(e) }
            v.onDragBegan = { [weak self] in self?.cancelPress() }
            v.onDragFinished = { [weak self] u, taken in if taken { self?.fileRemove(u) } }   // taken out: it leaves the pocket
        }
        c.fRevealB.target = self; c.fRevealB.action = #selector(revealFileTapped)
        c.fRemoveB.target = self; c.fRemoveB.action = #selector(removeFileTapped)
        c.hBar.onChange = { [weak self] v in self?.hudDragged(v) }
        c.progress.onScrub = { [weak self] f, final in self?.scrubbed(f, final: final) }
        view.dial.onDrag = { [weak self] dx, ph in self?.dialDragged(dx, ph) }
        view.onOpenSource = { [weak self] in self?.openSourceApp() }
        setupStatusItem()
        keyTap.onKey = { [weak self] code, down, fine in self?.handleMediaKey(code, down, fine) ?? false }
        setupKeyTap()
        refreshUI()
        scheduleStep(busy: true)
        watchOutputDevice()
        watchSleep()
        watchVolume()
        watchBattery()
        watchMusicApps()
        watchScreens()
        watchEscape()
        accessibilityLabels()
        let n0 = CFAbsoluteTimeGetCurrent()          // stagger the first polls so launch does not run every helper at once
        tMusic = n0 - 4; tAirPods = n0 - 25; tFiles = n0; tVolume = n0; tBattery = n0
    }

    // MARK: screen changes

    /// Display plugged / unplugged, resolution or arrangement changed: follow the notch screen and rebuild what is tied to it.
    func watchScreens() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let s = self else { return }
            let ns = App.pickScreen()
            s.screen = ns
            s.view.content.notchH = s.notchH
            s.link?.invalidate()
            s.link = ns.displayLink(target: s, selector: #selector(App.animTick(_:)))
            s.link?.add(to: .main, forMode: .common)
            s.link?.isPaused = false
            let r = s.frame(for: s.shape)
            s.mainP.x.jump(r.minX); s.mainP.w.jump(r.width); s.mainP.h.jump(r.height)
            s.mainP.x.tgt = r.minX; s.mainP.w.tgt = r.width; s.mainP.h.tgt = r.height
            s.pillP.x.jump(s.pillP.x.cur)
            s.atRest = false
            s.refreshUI()
        }
    }

    // MARK: Esc closes the open island

    func watchEscape() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, let s = self, s.pinned else { return }      // 53 = Esc (needs the Accessibility permission, like the key tap)
            if s.hudActive { s.hudUntil = .distantPast }
            s.pinned = false; s.alertText = nil; s.banner = nil
        }
    }

    func accessibilityLabels() {
        let labels: [(NSButton, String)] = [(c.prevB, "이전 곡"), (c.playB, "재생 / 일시정지"), (c.nextB, "다음 곡"),
                                            (c.pauseB, "타이머 일시정지 / 계속"), (c.cancelB, "타이머 취소"),
                                            (c.fRevealB, "Finder에서 보기"), (c.fRemoveB, "주머니에서 빼기")]
        for (b, t) in labels { b.setAccessibilityLabel(t); b.toolTip = t }
        c.hBar.setAccessibilityLabel("볼륨 / 밝기")
        c.progress.setAccessibilityLabel("재생 위치")
    }

    // MARK: event sources (instead of polling)

    private var volDev = AudioObjectID(0)
    private var volBlock: AudioObjectPropertyListenerBlock?
    private var batteryRL: CFRunLoopSource?
    private var musicDebounce: Timer?

    private func volAddresses() -> [AudioObjectPropertyAddress] {
        [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute].map {
            AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        }
    }
    /// Volume / mute changes of the current output device arrive as events; the slow poll is only a safety net.
    func watchVolume() {
        if let b = volBlock, volDev != 0 { for var a in volAddresses() { AudioObjectRemovePropertyListenerBlock(volDev, &a, .main, b) } }
        volBlock = nil; volDev = 0
        guard let d = SystemLevels.outputDevice() else { return }
        let b: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.pollVolume() }
        for var a in volAddresses() { AudioObjectAddPropertyListenerBlock(d, &a, .main, b) }
        volDev = d; volBlock = b
    }

    /// Plugging / unplugging and level changes arrive from IOKit: the banner shows at once and nothing polls.
    func watchBattery() {
        let cb: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let app = Unmanaged<App>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { app.pollBattery(); app.tBattery = CFAbsoluteTimeGetCurrent() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(cb, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes); batteryRL = src
        }
    }

    /// Music and Spotify announce every play / pause / track change: look up what is playing right then.
    func watchMusicApps() {
        let dc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            dc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let s = self else { return }
                s.musicDebounce?.invalidate()
                let t = Timer(timeInterval: 0.35, repeats: false) { [weak s] _ in s?.pollMusic(); s?.tMusic = CFAbsoluteTimeGetCurrent() }
                RunLoop.main.add(t, forMode: .common); s.musicDebounce = t
            }
        }
    }

    /// A new output device (AirPods connecting, ...) is the moment to look at the Bluetooth report, instead of polling it often.
    func watchOutputDevice() {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            self?.watchVolume()                      // the volume now belongs to another device
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.pollAirPods(); self?.tAirPods = CFAbsoluteTimeGetCurrent() }
        }
    }

    /// Asleep or screen off: nothing is visible, so stop the main loop entirely until the Mac wakes.
    func watchSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.stepTimer?.invalidate(); self?.stepTimer = nil }
        }
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                guard let s = self, s.stepTimer == nil else { return }
                s.scheduleStep(busy: true)
            }
        }
    }

    /// The main loop runs at 60Hz only while something is on screen or moving; when the island rests it drops to 30Hz
    /// (the light sensor's own rate), with a little tolerance so the system can coalesce the wakeups.
    var stepTimer: Timer?, stepBusy = false
    func scheduleStep(busy: Bool) {
        stepTimer?.invalidate()
        stepBusy = busy
        let t = Timer(timeInterval: busy ? 1.0 / 60 : 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
        t.tolerance = busy ? 0.002 : 0.006
        RunLoop.main.add(t, forMode: .common)       // .common: also runs while a menu is open or a drag is in progress
        stepTimer = t
    }

    /// Something is visible, moving, pressed or dragged: needs the full frame rate.
    var stepNeedsFullRate: Bool {
        shape != .collapsed || !atRest || hudActive || pressing || dragActive || dropping || scrollHolding || alertText != nil || banner != nil
    }

    func makePanel(_ frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Windows above the dragging level (500) cannot be drop targets, so stay just below it: still above menus and the Dock.
        p.level = NSWindow.Level(rawValue: 400)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false                                  // the system shadow draws a light rim; ShadowView draws a soft one instead
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return p
    }

    /// A click-through window with a soft shadow of `provider`'s shape, kept just behind `piece`.
    func attachShadow(to piece: Piece, _ provider: @escaping (CGSize) -> CGPath) {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: 399)                  // just under the island windows
        p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
        p.ignoresMouseEvents = true                              // never in the way of a click or a drop
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let v = ShadowView(frame: .zero)
        v.pathProvider = provider
        p.contentView = v
        piece.shadow = p
    }

    func symbolView(_ name: String, _ pt: CGFloat, _ tint: NSColor) -> NSImageView {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pt, weight: .semibold))
        v.contentTintColor = tint
        return v
    }

    /// The slot views of an activity. Files get theirs on demand: the file's own icon, nothing else.
    func slotItem(_ k: ActKind) -> SlotItem? {
        if let it = slotItems[k] { return it }
        guard case .file(let u) = k else { return nil }
        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: u.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let it = SlotItem(icon: icon, detail: NSView(), detailSize: .zero)
        slotItems[k] = it
        return it
    }

    func makeSlotItems() {
        slotItems[.media] = SlotItem(icon: ArtView(radius: 6), detail: EqView(), detailSize: CGSize(width: 20, height: 16))
        slotItems[.timer] = SlotItem(icon: TimerRing(),
                                     detail: makeLabel(13, .semibold, accent, mono: true, align: .right), detailSize: CGSize(width: 46, height: 18))
        slotItems[.charging] = SlotItem(icon: symbolView("bolt.fill", 15, bannerGreen),
                                        detail: makeLabel(13, .semibold, bannerGreen, mono: true, align: .center), detailSize: CGSize(width: 38, height: 18))
        slotItems[.lowBattery] = SlotItem(icon: symbolView("battery.25percent", 16, bannerRed),
                                          detail: makeLabel(13, .semibold, bannerRed, mono: true, align: .center), detailSize: CGSize(width: 38, height: 18))
        slotItems[.airpods] = SlotItem(icon: symbolView("airpods", 17, .white), detail: RingView(), detailSize: CGSize(width: 24, height: 24))
    }

    /// Demos: a stopwatch, or (NI_COUNTDOWN=1) a one-minute timer.
    func startDemoTimer() {
        if ProcessInfo.processInfo.environment["NI_COUNTDOWN"] != nil { timer.startCountdown(minutes: 1) } else { timer.toggle() }
    }

    func wire(_ b: NSButton, _ sel: Selector) { b.target = self; b.action = sel }

    // MARK: actions

    @objc func prevTapped() { if demoMedia { return }; sendMediaCommand(5); pollSoon() }
    @objc func nextTapped() { if demoMedia { return }; sendMediaCommand(4); pollSoon() }
    @objc func playPauseTapped() {
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
        if !files.isEmpty { add("주머니 비우기 (\(files.count))", #selector(filesClear)) }
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
        guard let id = media?.bundleID, !id.isEmpty else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            running.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        pinned = false                               // go back to the compact island once the app is in front
    }

    @objc func timerToggleTapped() { timer.toggle(); refreshUI() }
    @objc func timerCancelTapped() { timer.reset(); refreshUI() }
    func pollSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pollMusic() } }

    /// Which activity is under the pointer. Anything on the notch itself or to the left of it is the activity attached
    /// to the notch on the left (the first one); the right wing, the detached icon and the pill pick their own.
    func kindAtMouse() -> ActKind? {
        let a = acts
        guard !a.isEmpty else { return nil }
        let m = NSEvent.mouseLocation
        if pillP.active, a.count >= 3, pillP.panel.frame.insetBy(dx: -6, dy: -6).contains(m) {
            let items = Array(a.dropFirst(2)), f = pillP.panel.frame
            return items[min(items.count - 1, max(0, Int((m.x - f.minX) / max(f.width, 1) * CGFloat(items.count))))]
        }
        if a.count >= 2, m.x > notchRight { return a[1] }
        return a[0]
    }

    /// Finger down: react at once (swell; the trackpad's own click is the only haptic). With something running, a quick tap opens it on release,
    /// and holding opens it after 0.25s without waiting for the release. With nothing running it pops out and back.
    func pressBegan() {
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
            let zone = s.frame(for: s.shape)
            guard zone.insetBy(dx: -40, dy: -40).contains(NSEvent.mouseLocation) else { return }   // dragged away while holding: do nothing
            s.pressing = false
            s.selected = s.pressKind
            s.pinned = true                          // popped out: stays out until you click elsewhere
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
        }
        if pressedWhileExpanded && inside {          // tapping the open island shrinks it back
            if hudActive { hudUntil = .distantPast }
            else { pinned = false; alertText = nil; banner = nil }
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

    // MARK: files (the pocket)

    func fileAdd(_ urls: [URL]) {
        for u in urls where !files.contains(u) { files.append(u) }
        syncActivities(); fileSave(); refreshUI()
    }
    func fileRemove(_ u: URL) {
        files.removeAll { $0 == u }; slotItems.removeValue(forKey: .file(u))
        syncActivities(); fileSave(); refreshUI()
    }
    @objc func filesClear() {
        for u in files { slotItems.removeValue(forKey: .file(u)) }
        files.removeAll(); syncActivities(); fileSave(); refreshUI()
    }
    func fileSave() {
        guard demoShelf == nil else { return }
        UserDefaults.standard.set(files.map { $0.path }, forKey: "pocketFiles")
    }
    func fileLoad() {
        let paths = demoShelf ?? UserDefaults.standard.stringArray(forKey: "pocketFiles") ?? []
        files = Array(paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }.suffix(5))
    }
    @objc func revealFileTapped() { if case .file(let u)? = cardKind { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc func removeFileTapped() { if case .file(let u)? = cardKind { fileRemove(u); pinned = false } }

    func fileSubtitle(_ u: URL) -> String {
        if let c = fileInfo[u] { return c }
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let info = [u.deletingLastPathComponent().lastPathComponent, size].compactMap { $0 }.joined(separator: " · ")
        fileInfo[u] = info
        return info
    }

    /// The file a drag starting at the pointer would carry: the open file card's icon / name, or a file icon in the compact island.
    func fileForDrag(_ e: NSEvent) -> URL? {
        if shape == .expanded {
            guard body == .file, case .file(let u)? = cardKind else { return nil }
            return c.fIcon.frame.union(c.fName.frame).contains(c.convert(e.locationInWindow, from: nil)) ? u : nil
        }
        if case .file(let u)? = kindAtMouse() { return u }
        return nil
    }
    func cancelPress() { longPressTimer?.invalidate(); longPressTimer = nil; pressing = false }

    /// Called every frame: is a file drag (from Finder...) in progress, and is it near the notch?
    func trackFileDrag(_ m: NSPoint) {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down && !wasBtn { downChange = NSPasteboard(name: .drag).changeCount; dragActive = false }
        if down, !dragActive {                          // the drag pasteboard is only looked at while the button is held
            let pb = NSPasteboard(name: .drag)
            if pb.changeCount != downChange, pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { dragActive = true }
        }
        if !down { dragActive = false; dragEntered = false }
        wasBtn = down
        let zone = dropping ? frame(for: .expanded).insetBy(dx: -30, dy: -30)
                            : NSRect(x: screen.frame.midX - 110, y: screen.frame.maxY - 70, width: 220, height: 70)
        let near = dragActive && zone.contains(m)
        if near != dragNear { dragNear = near }
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
        let kt = Timer(timeInterval: 5, repeats: true) { _ in tryInstall() }   // picks up a later grant
        kt.tolerance = 2
        RunLoop.main.add(kt, forMode: .common); keyTapTimer = kt
    }

    func showBanner(_ k: BannerKind, autoHide: TimeInterval? = nil) {
        banner = k
        bannerHideAt = autoHide.map { Date().addingTimeInterval($0) }      // nil: stays until you click somewhere else
        pinned = true
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

    var tAppearance = 0.0, tFiles = 0.0, tVolume = 0.0, tBattery = 0.0, tMusic = 0.0, tAirPods = 0.0
    /// True (and re-arms `last`) when `every` seconds have passed since it last was.
    func due(_ last: inout Double, _ every: Double) -> Bool {
        let n = CFAbsoluteTimeGetCurrent()
        guard n - last >= every else { return false }
        last = n; return true
    }

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

        if !stepBusy || tick % 2 == 0 {            // 30Hz in both modes: the ambient light sensor is the touch sensor
            let v = simLux ?? als_read()              // simLux is only set by the test hook below
            if v >= 0 { lux = v; sensorMisses = 0 }   // raw value, no smoothing; hysteresis below prevents flicker
            else { sensorMisses += 1; if sensorMisses >= 60 { lux = -1 } }   // ~2s of silence: stop trusting old data
            let wasCovered = darkLatched
            // in a dim room covering the sensor hardly changes the reading: the bar follows the room's own light (but never above `threshold`)
            let thr = max(2, ambient > 0 ? min(threshold, ambient * 0.3) : threshold)
            if lux >= 0 && lux < thr { darkLatched = true }                  // covered  = finger down
            else if lux < 0 || lux > thr * 1.2 { darkLatched = false }       // uncovered = finger up
            if !darkLatched && lux >= 0 { ambient = ambient < 0 ? lux : ambient * 0.98 + lux * 0.02 }
            if darkLatched && !wasCovered { sensorTouchBegan() }
            else if !darkLatched && wasCovered { sensorTouchEnded() }
        }
        if let t = bannerHideAt, now > t {                      // a timed banner (AirPods connecting) goes away by itself
            bannerHideAt = nil
            if case .airpods? = banner { banner = nil; if selected == nil { pinned = false } }
        }
        if mainP.m.cur > 0.5 || mainP.m.tgt > 0 {             // only the island and the dial take the pointer; the margin is click-through
            let pf = panel.frame, mp = NSEvent.mouseLocation
            let bodyR = NSRect(x: pf.minX, y: pf.minY + mainP.m.cur, width: pf.width, height: pf.height - mainP.m.cur)
            let stripR = NSRect(x: pf.minX, y: pf.minY, width: pf.width, height: mainP.m.cur + 8)
            let ign = !(bodyR.contains(mp) || stripR.contains(mp) || (scrollHolding && pf.contains(mp)))
            if panel.ignoresMouseEvents != ign { panel.ignoresMouseEvents = ign }
        } else if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
        if due(&tAppearance, 2) { view.dial.lightAppearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua }   // tick colour follows light / dark mode
        trackFileDrag(NSEvent.mouseLocation)
        if due(&tFiles, 5), files.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) {       // deleted elsewhere
            files = files.filter { FileManager.default.fileExists(atPath: $0.path) }; fileSave()
        }
        if due(&tVolume, 2) { pollVolume() }       // safety net only: volume changes normally arrive as events (watchVolume)
        if due(&tBattery, 5) { pollBattery() }     // safety net + the 'fully charged' timer; plug events arrive from IOKit (watchBattery)
        // each lookup spawns osascript: poll faster only while a track is playing or the card is open
        if due(&tMusic, shape == .expanded ? 2 : (media?.playing == true ? 3 : 5)) { pollMusic() }
        if let m = media, !m.playing, !demoMedia, demoActsN == nil, shape != .expanded,
           now.timeIntervalSince(lastPlayingAt) > 4 { media = nil }     // paused for a while: let it go
        if due(&tAirPods, 30) { pollAirPods() }    // system_profiler is heavy; a new output device triggers it sooner (see watchOutputDevice)

        
        prevTimerStarted = timer.started
        if timer.finished {                        // countdown just hit zero
            timer.reset()
            NSSound.beep()
            showAlert("타이머 종료", seconds: 6)
        }

        if !liveActivity && shape == .collapsed && atRest && !pinned && !stepBusy {
            if !idleRefreshed { idleRefreshed = true; refreshUI() }     // resting and empty: one last refresh, then nothing to redraw
        } else {
            idleRefreshed = false
            if tick % (stepBusy ? 6 : 3) == 0 { refreshUI() }           // content at 10Hz; shape/hover/press every frame
        }
        applyShape()
        if stepNeedsFullRate != stepBusy { scheduleStep(busy: !stepBusy) }
    }

    func pollBattery() {
        guard let b = readBattery() else { return }
        defer { battery = b }
        guard let old = battery else { return }
        if b.plugged != old.plugged {
            if b.plugged { chargeShownUntil = Date().addingTimeInterval(3) }
            if !b.plugged { showBanner(.battery(title: "충전 해제", level: b.level, color: .white)) }     // plugging in: the charging activity just appears, quietly
            notifiedFull = false; fullSince = nil
        }
        if b.plugged {
            warned20 = false; warned10 = false
            if isFull(b) {
                if fullSince == nil { fullSince = Date() }
                // right after plugging in, `charging` can read false for a moment: only trust "full" once it has held for a while
                if !notifiedFull, Date().timeIntervalSince(fullSince!) >= 8 { notifiedFull = true; showBanner(.battery(title: "충전 완료", level: b.level, color: bannerGreen)) }
            } else { fullSince = nil }
        } else {
            if b.level <= 10 && !warned10 { warned10 = true; warned20 = true }          // the low-battery activity appears by itself, quietly
            else if b.level <= 20 && !warned20 { warned20 = true }
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
            for d in list where !airKnown.contains(d.name) { showBanner(.airpods(symbol: d.symbol, level: d.level), autoHide: 4) }   // only at the moment of connecting
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
        case .nothing:
            nothingPolls += 1                            // a track change can answer 'nothing' for a moment: wait for a second answer
            if nothingPolls >= 2 || media?.playing == false { media = nil }
            mediaBaseline = true; return
        case .media(let m): r = m; nothingPolls = 0
        }
        defer { mediaBaseline = true }
        if Date() < seekHoldUntil, case .media(let n) = result, media != nil, n.title == media?.title { return }   // stale position right after a seek
        if r.playing { lastPlayingAt = Date() }
        // keep a paused track around for a while so it can be resumed from the island
        // A paused track is only KEPT while it is already showing (so it can be resumed from the island).
        // Once it has gone away it never comes back by itself: only playing again starts a new activity.
        if !r.playing {
            guard media != nil, shape == .expanded || Date().timeIntervalSince(lastPlayingAt) < 4 else { media = nil; return }
        }
        let started = media == nil                   // playback just started (a track change alone never opens the card)
        media = r
        loadArtwork(for: r)
        _ = started                                  // a new music activity appears quietly: it never opens the card by itself
    }

    var artRetryAt: [String: Date] = [:], artTries: [String: Int] = [:]
    func artworkKey(_ m: Media) -> String { m.storeID.isEmpty ? "t:\(m.title)|\(m.artist)" : m.storeID }

    func loadArtwork(for m: Media) {
        let id = artworkKey(m)
        guard id != artworkFor else { return }
        if let t = artRetryAt[id], Date() < t { return }              // a failed lookup is retried later, not on every poll
        artworkFor = id
        // keep showing the previous cover until the new one has arrived, so it fades once instead of flashing
        if let hit = artCache[id] { artwork = hit.0; artColor = hit.1; return }
        let tries = artTries[id, default: 0]
        artTries[id] = tries + 1
        let done: (NSImage?) -> Void = { [weak self] img in
            guard let s = self else { return }
            guard let img = img else {
                DispatchQueue.main.async {
                    guard s.artworkFor == id else { return }
                    if m.storeID.isEmpty && tries >= 1 { return }      // no cover to be had for this track (at most two tries)
                    s.artworkFor = ""; s.artRetryAt[id] = Date().addingTimeInterval(30)
                    if m.storeID.isEmpty { s.artwork = nil; s.artColor = accent }
                }
                return
            }
            let col = averageColor(img)
            DispatchQueue.main.async {
                s.artCache[id] = (img, col)
                if s.artCache.count > 40 { s.artCache.removeValue(forKey: s.artCache.keys.first!) }
                if s.artworkFor == id { s.artwork = img; s.artColor = col }
            }
        }
        if m.storeID.isEmpty {                                        // Spotify, browsers...: the cover comes with the now-playing info
            artwork = nil; artColor = accent
            DispatchQueue.global(qos: .utility).async { done(queryArtworkData()) }
        } else {
            fetchArtwork(storeID: m.storeID, completion: done)
        }
    }

    // MARK: rendering

    func setText(_ f: NSTextField, _ s: String) { if f.stringValue != s { f.stringValue = s } }

    func refreshUI() {
        syncActivities()
        let b = body
        c.body = b
        c.ending = b == .none && acts.isEmpty
        c.bandH = (shape == .expanded || (shape == .collapsed && atRest)) ? notchH : compactH

        populate(c, bn: displayBanner, kind: cardKind)
        if let k = cardKind, let i = acts.firstIndex(of: k) {           // the wheel follows the shown activity (and a finger on it)
            view.dial.count = acts.count
            if Date().timeIntervalSince(lastScrollAt) > 0.6 {
                // the wheel only ever turns the short way round to the shown activity (it may have been spun several times)
                let n = CGFloat(acts.count)
                let near = CGFloat(i) + n * ((view.dial.position - CGFloat(i)) / n).rounded()
                dialPos = near; view.dial.set(near, animated: true)
            }
        }
        let dialOn = shape == .expanded && dialShown
        if dialOn != dialWasOn {
            dialWasOn = dialOn
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = dialOn ? 0.3 : 0.18; view.dial.animator().alphaValue = dialOn ? 1 : 0 }
        }

        // volume / brightness HUD (the main island only)
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

        refreshSlots()
        let plan = makePlan()
        if plan != lastPlan { lastPlan = plan; placeSlots(plan) }
        c.needsLayout = true
        c.applyVisibility(expanded: shape == .expanded)
    }

    /// Fills the card of one island (the main one or the second notch) with the data of the activity it shows.
    func populate(_ c: Content, bn: BannerKind?, kind: ActKind?) {
        // timer pieces
        setText(c.tTime, timer.text())
        setText(c.tLabel, timer.mode == .stopwatch ? "스톱워치" : "타이머")
        setSymbol(c.pauseB, timer.running ? "pause.fill" : "play.fill", 20)

        // banner (charging / low battery / AirPods)
        if let bn = bn {
            switch bn {
            case .battery(let title, let level, let color):
                c.bannerIsAir = false
                setText(c.bTitle, title); setText(c.bPct, "\(level)%")
                c.bPct.textColor = color
                c.bGlyph.fraction = CGFloat(level) / 100; c.bGlyph.color = color
            case .airpods(let symbol, let level):
                c.bannerIsAir = true
                if symbol != c.bannerSymbol {
                    c.bannerSymbol = symbol
                    c.bAir.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 21, weight: .regular))
                    c.bAir.contentTintColor = .white
                }
                c.bRing.fraction = CGFloat(level ?? 0) / 100
            }
        }

        // file card
        if case .file(let u)? = kind, c.fileShown != u {
            c.fileShown = u
            c.fIcon.image = NSWorkspace.shared.icon(forFile: u.path)
            setText(c.fName, u.lastPathComponent)
            setText(c.fSub, fileSubtitle(u))
        }

        // media pieces
        if let m = media {
            setText(c.titleL, m.title)
            setText(c.artistL, m.artist)
            c.art.setImage(artwork)
            let e = seekFraction.map { Double($0) * m.duration } ?? m.elapsedNow
            setText(c.elapsedL, mmss(e))
            setText(c.remainL, m.duration > 0 ? "-" + mmss(m.duration - e) : "")
            c.progress.fraction = m.duration > 0 ? CGFloat(e / m.duration) : 0
            c.progress.isHidden = m.duration <= 0
            setSymbol(c.playB, m.playing ? "pause.fill" : "play.fill", 30)
            c.bodyEq.color = artColor; c.bodyEq.setPlaying(m.playing && shape == .expanded && body == .media)    // hidden bars do not animate
        }
    }

    /// Updates what the small slot views show.
    func refreshSlots() {
        if let m = media, let it = slotItem(.media), let art = it.icon as? ArtView, let eq = it.detail as? EqView {
            art.setImage(artwork); eq.color = artColor; eq.setPlaying(m.playing && usedViews.contains(where: { $0 === eq }))
        }
        if let it = slotItem(.timer), let l = it.detail as? NSTextField {
            setText(l, timer.text())
            if let ring = it.icon as? TimerRing {
                ring.countdown = timer.mode == .countdown
                ring.fraction = timer.mode == .countdown
                    ? CGFloat(timer.target > 0 ? max(0, timer.target - timer.elapsed) / timer.target : 0)     // shrinks
                    : CGFloat(timer.elapsed.truncatingRemainder(dividingBy: 60) / 60)                           // fills, a lap a minute
            }
        }
        if let it = slotItem(.charging), let l = it.detail as? NSTextField { setText(l, "\(chargeLevel)%") }
        if let it = slotItem(.lowBattery), let l = it.detail as? NSTextField {
            setText(l, "\(lowLevel)%")
            let col = lowLevel <= 10 ? bannerRed : accent
            l.textColor = col; (it.icon as? NSImageView)?.contentTintColor = col
        }
        if let it = slotItem(.airpods), let d = airInfo, let ring = it.detail as? RingView, let icon = it.icon as? NSImageView {
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
        if let lk = plan.left, let it = slotItem(lk) {
            // a single activity: icon on the left, detail on the right. Several: the compact view (icon, or % for charging)
            let v = plan.rightDetail ? (view: it.icon, size: CGSize(width: 24, height: 24)) : slotView(lk)
            c.leftView = v.view; c.leftSize = v.size
            use(v.view, in: c)
        } else { c.leftView = nil }
        if let rk = plan.right, let it = slotItem(rk) {
            let v = plan.rightDetail ? (view: it.detail, size: it.detailSize) : slotView(rk)
            c.rightView = v.view; c.rightSize = v.size
            use(v.view, in: c)
        } else { c.rightView = nil }
        let pitems = plan.pill.compactMap { slotItem($0) }
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
        if forceOpen || pinned || hudActive || dropping { return .expanded }
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
            if target == .expanded { fileInfo.removeAll(); c.fileShown = nil }   // size / folder may have changed since it was last opened
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
        // While you scroll, the invisible margin under the island keeps its old extent (the card itself shrinks to fit), so the
        // pointer stays inside the window even when the next card is lower. It is let go a second after the last scroll.
        if !scrollHolding { holdH = 0 }
        let holdExtra = scrollHolding ? max(0, holdH - r.height) : 0
        if abs(dialMargin + holdExtra - mainP.m.tgt) > 0.01 { mainP.m.tgt = dialMargin + holdExtra; wake = true }
        if abs(r.minX - mainP.x.tgt) > 0.01 || abs(r.width - mainP.w.tgt) > 0.01 || abs(r.height - mainP.h.tgt) > 0.01 {
            mainP.x.tgt = r.minX; mainP.w.tgt = r.width; mainP.h.tgt = r.height
            wake = true
        }
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
                if let sh = p.shadow { sh.orderFrontRegardless(); makeSticky(sh) }
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
        for p in [mainP!, pillP!] where p.active || p.visible {
            let isMain = p === mainP
            let k: CGFloat = isMain ? stiffness : 300, cd: CGFloat = isMain ? damping : 28
            for _ in 0..<steps { p.x.step(h, k, cd); p.w.step(h, k, cd); p.h.step(h, k, cd); p.ty.step(h, k, cd); p.m.step(h, k, cd) }
            if isMain {
                // Momentum from an interrupted move must never uncover the hardware notch.
                if p.x.cur > notchLeft { p.x.cur = notchLeft; if p.x.vel > 0 { p.x.vel = 0 } }
                if p.x.cur + p.w.cur < notchRight { p.w.cur = notchRight - p.x.cur; if p.w.vel < 0 { p.w.vel = 0 } }
                if p.h.cur < notchH { p.h.cur = notchH; if p.h.vel < 0 { p.h.vel = 0 } }
            }
            if p.settled { p.snap() } else { allSettled = false }
            if !p.active && p.settled && p.w.cur < 1.5 {          // shrunk away: take the window off screen
                p.panel.orderOut(nil); p.shadow?.orderOut(nil); p.visible = false; p.w.jump(0)
                continue
            }
            if !isMain { p.panel.alphaValue = p.fullW > 0 ? min(1, max(0, p.w.cur / p.fullW)) : 0 }
            let margin = max(p.m.cur, 0)
            let f = NSRect(x: p.x.cur, y: screen.frame.maxY - p.ty.cur - p.h.cur, width: max(p.w.cur, 1), height: max(p.h.cur, 1))   // the island
            if isMain { view.bottomInset = margin }
            p.panel.setFrame(NSRect(x: f.minX, y: f.minY - margin, width: f.width, height: f.height + margin), display: true)
            if let sh = p.shadow {
                sh.setFrame(f.insetBy(dx: -ShadowView.pad, dy: -ShadowView.pad), display: true)
                sh.alphaValue = p.panel.alphaValue
            }
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
