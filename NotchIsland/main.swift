import AppKit
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
    default: break
    }
}

let accent = NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)   // timer orange
let bannerGreen = NSColor(red: 0.35, green: 0.9, blue: 0.5, alpha: 1)
let bannerRed = NSColor(red: 1.0, green: 0.35, blue: 0.3, alpha: 1)

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
    if (title) {
      var pos = null;
      try { pos = item.metadata.calculatedPlaybackPosition; } catch (e) {}
      out = JSON.stringify({
        title: title,
        artist: g("kMRMediaRemoteNowPlayingInfoArtist") || "",
        rate: g("kMRMediaRemoteNowPlayingInfoPlaybackRate") || 0,
        duration: g("kMRMediaRemoteNowPlayingInfoDuration") || 0,
        elapsed: (pos !== null && pos !== undefined) ? pos : (g("kMRMediaRemoteNowPlayingInfoElapsedTime") || 0),
        id: String(g("kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier") || "")
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
                        duration: num("duration"), elapsed: num("elapsed"), readAt: Date(), storeID: (j["id"] as? String) ?? ""))
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

final class TimerModel {
    enum Mode { case stopwatch, countdown }
    var mode: Mode = .stopwatch
    var running = false
    var target: TimeInterval = 300       // countdown length
    private var accumulated: TimeInterval = 0
    private var startedAt: Date?

    var elapsed: TimeInterval { accumulated + (running ? Date().timeIntervalSince(startedAt ?? Date()) : 0) }
    var display: TimeInterval { mode == .stopwatch ? elapsed : max(0, target - elapsed) }
    var finished: Bool { mode == .countdown && elapsed >= target }

    func toggle() {
        if running { accumulated = elapsed; running = false; startedAt = nil }
        else { if finished { reset() }; startedAt = Date(); running = true }
    }
    var started: Bool { running || accumulated > 0 }
    func reset() { running = false; accumulated = 0; startedAt = nil; target = 300 }
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
            l.removeAllAnimations()
            if p {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = 0.25; a.toValue = 1.0
                a.duration = 0.42 + Double(i) * 0.11
                a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.timeOffset = Double(i) * 0.13
                l.add(a, forKey: "eq")
            } else {
                l.transform = CATransform3DMakeScale(1, 0.3, 1)
            }
        }
    }
}

final class ProgressBar: NSView {
    private let fill = CALayer()
    var fraction: CGFloat = 0 { didSet { relayout() } }
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
        didSet { CATransaction.begin(); CATransaction.setDisableActions(true)
                 prog.strokeEnd = min(max(fraction, 0), 1); CATransaction.commit() }
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

// MARK: - Content (flipped: y grows downward from the top of the island)

enum Body { case none, banner, alert, media, timer }
enum LeftWing { case none, art, timer }
enum RightWing { case none, eq, time }

final class Content: Flip {
    var notchH: CGFloat = 32
    var bandH: CGFloat = 32          // height of the top band the wings live in (taller while compact)
    var body: Body = .none
    var left: LeftWing = .none
    var right: RightWing = .none
    private var lastAlpha: [ObjectIdentifier: CGFloat] = [:]

    // wings
    let wingArt = ArtView(radius: 10)      // = pill corner (18) - margin (8): corners stay concentric
    let wingTimerIcon = NSImageView()
    let wingEq = EqView()
    let wingTime = makeLabel(13, .semibold, accent, mono: true, align: .right)
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
    let tTime = makeLabel(38, .semibold, accent, mono: true, align: .right)
    // banner body (charging / AirPods): a pill as tall as the notch, content on both sides of it
    var bannerIsAir = false
    let bTitle = makeLabel(16, .semibold, .white)
    let bPct = makeLabel(16, .semibold, bannerGreen, mono: true, align: .right)
    let bGlyph = BatteryGlyph()
    let bAir = NSImageView()
    let bRing = RingView()
    // alert body
    let alertL = makeLabel(15, .semibold, .white, align: .center)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wingTimerIcon.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        wingTimerIcon.contentTintColor = accent
        for b in [pauseB, cancelB] { b.wantsLayer = true; b.layer?.cornerRadius = 23 }
        pauseB.layer?.backgroundColor = accent.withAlphaComponent(0.28).cgColor
        cancelB.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        for v in all { addSubview(v); v.alphaValue = 0 }
    }
    required init?(coder: NSCoder) { fatalError() }

    var all: [NSView] {
        [wingArt, wingTimerIcon, wingEq, wingTime, art, titleL, artistL, bodyEq, progress, elapsedL, remainL,
         prevB, playB, nextB, pauseB, cancelB, tLabel, tTime, alertL, bTitle, bPct, bGlyph, bAir, bRing]
    }

    override func layout() {
        super.layout()
        let w = bounds.width, pad: CGFloat = 18, top = notchH + 4
        // wings: the art tile gets the same margin on the left, top and bottom
        let tile: CGFloat = 24
        let m = max((bandH - tile) / 2, 0)
        let leftInset: CGFloat = bandH > notchH ? m : 14        // compact pill: even margins; expanded: wing icons
        let rightInset: CGFloat = bandH > notchH ? m + 6 : 14
        wingArt.frame = NSRect(x: leftInset, y: m, width: tile, height: tile)
        wingTimerIcon.frame = NSRect(x: leftInset, y: m, width: tile, height: tile)
        wingEq.frame = NSRect(x: w - rightInset - 20, y: (bandH - 16) / 2, width: 20, height: 16)
        wingTime.frame = NSRect(x: w - rightInset - 70, y: (bandH - 18) / 2, width: 70, height: 18)
        // media
        art.frame = NSRect(x: pad, y: top, width: 52, height: 52)
        let tx = pad + 52 + 12, tw = max(0, w - tx - pad - 28)
        titleL.frame = NSRect(x: tx, y: top + 7, width: tw, height: 20)
        artistL.frame = NSRect(x: tx, y: top + 28, width: tw, height: 18)
        bodyEq.frame = NSRect(x: w - pad - 20, y: top + 8, width: 20, height: 20)
        progress.frame = NSRect(x: pad, y: top + 62, width: w - 2 * pad, height: 5)
        elapsedL.frame = NSRect(x: pad, y: top + 70, width: 60, height: 14)
        remainL.frame = NSRect(x: w - pad - 60, y: top + 70, width: 60, height: 14)
        let cy = top + 88
        playB.frame = NSRect(x: w / 2 - 25, y: cy, width: 50, height: 36)
        prevB.frame = NSRect(x: w / 2 - 25 - 80, y: cy, width: 50, height: 36)
        nextB.frame = NSRect(x: w / 2 - 25 + 80, y: cy, width: 50, height: 36)
        // timer
        pauseB.frame = NSRect(x: pad, y: top + 4, width: 46, height: 46)
        cancelB.frame = NSRect(x: pad + 56, y: top + 4, width: 46, height: 46)
        tLabel.frame = NSRect(x: w - pad - 190, y: top - 2, width: 190, height: 16)
        tTime.frame = NSRect(x: w - pad - 190, y: top + 12, width: 190, height: 46)
        // banner
        bTitle.frame = NSRect(x: 20, y: (notchH - 20) / 2, width: 130, height: 20)
        bAir.frame = NSRect(x: 20, y: (notchH - 26) / 2, width: 30, height: 26)
        bGlyph.frame = NSRect(x: w - 20 - 34, y: (notchH - 15) / 2, width: 34, height: 15)
        bPct.frame = NSRect(x: w - 20 - 34 - 8 - 60, y: (notchH - 20) / 2, width: 60, height: 20)
        bRing.frame = NSRect(x: w - 20 - 26, y: (notchH - 26) / 2, width: 26, height: 26)
        // alert
        alertL.frame = NSRect(x: pad, y: notchH + 8, width: w - 2 * pad, height: 22)
    }

    /// Cross-fade every element to what the current shape/body/wings need.
    func applyVisibility(expanded: Bool) {
        let b = body
        let ending = (b == .none && left == .none && right == .none)
        let want: [(NSView, Bool)] = [
            (wingArt, left == .art), (wingTimerIcon, left == .timer),
            (wingEq, right == .eq), (wingTime, right == .time),
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
        ]
        for (v, on) in want {
            let a: CGFloat = on ? 1 : 0
            let key = ObjectIdentifier(v)
            if lastAlpha[key] == a { continue }
            lastAlpha[key] = a
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = on ? 0.28 : (ending ? 0.65 : 0.14)      // a finished activity fades out unhurriedly
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]   // round only the bottom corners
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 18pt for the compact pill, easing up to 34pt for the big card; never more than half the height
        let r = min(34, max(18, 18 + (bounds.height - 40) * 0.5))
        layer?.cornerRadius = min(r, bounds.height / 2)
    }

    // Labels must not swallow presses; only visible buttons keep their own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point) else { return nil }
        if v is NSButton, !v.isHidden, v.alphaValue > 0.3 { return v }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func mouseUp(with event: NSEvent) {
        onRelease?(bounds.contains(convert(event.locationInWindow, from: nil)))
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    enum Shape { case collapsed, activity, peek, pressed, expanded }

    // press / long-press state
    var pressing = false                 // finger down on a closed island, long-press not yet fired
    var pressedWhileExpanded = false
    var longPressTimer: Timer?

    // spring-driven window size (smooth, interruptible, velocity-preserving)
    var link: CADisplayLink?
    var curW: CGFloat = 0, curH: CGFloat = 0, velW: CGFloat = 0, velH: CGFloat = 0
    var tgtW: CGFloat = 0, tgtH: CGFloat = 0
    var stiffness: CGFloat = 400, damping: CGFloat = 30
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

    var body: Body {
        if banner != nil { return .banner }
        if alertText != nil { return .alert }
        if media != nil { return .media }
        if timer.started { return .timer }
        return .none
    }
    var liveActivity: Bool { body != .none }
    var expandedExtra: CGFloat {
        switch body {
        case .media:  return 136
        case .timer:  return 72
        case .banner: return 0
        default:      return 42
        }
    }

    func wings() -> (LeftWing, RightWing) {
        let m = media != nil, t = timer.started
        if shape == .expanded {
            switch body {
            case .media: return t ? (.timer, .time) : (.none, .none)
            case .timer: return m ? (.art, .eq) : (.none, .none)
            default:     return (.none, .none)   // banner / alert: nothing beside it
            }
        }
        return (m ? .art : (t ? .timer : .none), t ? .time : (m ? .eq : .none))
    }

    func frame(for s: Shape) -> NSRect {
        let (w, h): (CGFloat, CGFloat)
        let hasCompact = media != nil || timer.started
        let base: CGFloat = hasCompact ? notchW + 160 : notchW   // peek/pressed grow from here
        switch s {
        case .collapsed: (w, h) = (notchW, notchH)
        case .activity:  (w, h) = (notchW + 160, notchH + 8)    // a little taller so the art tile gets even margins
        case .peek:      (w, h) = (base + 24, hasCompact ? notchH + 8 : notchH)    // swells sideways only
        case .pressed:   (w, h) = (base + 44, hasCompact ? notchH + 8 : notchH)    // swells further sideways
        case .expanded:  (w, h) = body == .banner ? (notchW + 250, notchH) : (400, notchH + expandedExtra)
        }
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = NSPanel(contentRect: frame(for: .collapsed), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        view = IslandView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.content.notchH = notchH
        view.autoresizingMask = [.width, .height]
        view.onPress = { [weak self] in self?.pressBegan() }
        view.onRelease = { [weak self] inside in self?.pressEnded(inside: inside) }
        wire(c.prevB, #selector(prevTapped)); wire(c.playB, #selector(playPauseTapped)); wire(c.nextB, #selector(nextTapped))
        wire(c.pauseB, #selector(timerToggleTapped)); wire(c.cancelB, #selector(timerCancelTapped))
        panel.contentView = view
        panel.orderFrontRegardless()
        let sz = frame(for: .collapsed).size
        curW = sz.width; curH = sz.height; tgtW = sz.width; tgtH = sz.height
        link = screen.displayLink(target: self, selector: #selector(animTick(_:)))
        link?.add(to: .main, forMode: .common)
        link?.isPaused = true

        if let t = demoAlert { showAlert(t) }
        if demoTimer { timer.toggle(); pinned = true }
        if demoCharging { showBanner(.battery(title: "충전 중", level: 55, color: bannerGreen)) }
        if demoAirpods { showBanner(.airpods(symbol: "airpodspro", level: 80)) }
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
            signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN); signal(SIGWINCH, SIG_IGN)
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
        refreshUI()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
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
    @objc func timerToggleTapped() { haptic(); timer.toggle(); refreshUI() }
    @objc func timerCancelTapped() { haptic(); timer.reset(); refreshUI() }
    func pollSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pollMusic() } }

    /// Finger down: react at once (swell + haptic). With something running, a quick tap opens it on release,
    /// and holding opens it after 0.25s without waiting for the release. With nothing running it pops out and back.
    func pressBegan() {
        haptic(.alignment)
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
            pinned = true
            haptic(.levelChange)
        }
        if pressedWhileExpanded && inside {          // tapping the open island shrinks it back
            pinned = false; alertText = nil; banner = nil
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
            pinned = false; alertText = nil; banner = nil
            haptic(.levelChange)
            return
        }
        if !liveActivity { popUntil = Date().addingTimeInterval(0.22); return }
        pressing = true
        longPressTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let s = self, s.pressing, s.darkLatched else { return }   // still covered
            s.pressing = false
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
        if probe.contains(m) { hoverUntil = now.addingTimeInterval(0.25) }

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
        if tick % 120 == 0 { pollBattery() }       // 2s
        if tick % 120 == 47 { pollMusic() }        // 2s, offset from battery
        if let m = media, !m.playing, !demoMedia, shape != .expanded,
           now.timeIntervalSince(lastPlayingAt) > 4 { media = nil }     // paused for a while: let it go
        if tick % 360 == 211 { pollAirPods() }     // 6s

        if timer.started && !prevTimerStarted { pinned = true; haptic(.levelChange) }   // stopwatch started: open it
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
        if airBaseline {                             // the first poll only records what is already connected
            for d in list where !airKnown.contains(d.name) { showBanner(.airpods(symbol: d.symbol, level: d.level)) }
        }
        airKnown = Set(list.map { $0.name }); airBaseline = true
    }

    func pollMusic() {
        guard !musicBusy, !demoMedia, ProcessInfo.processInfo.environment["NI_NOMEDIA"] == nil else { return }   // NI_NOMEDIA=1: test hook
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
        guard r.playing || shape == .expanded || Date().timeIntervalSince(lastPlayingAt) < 4 else { media = nil; return }
        let isNew = media == nil || media?.title != r.title
        media = r
        loadArtwork(for: r.storeID)
        if mediaBaseline && r.playing && isNew {     // playback just started / the track changed: open the card at once
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
        let b = body
        c.body = b
        c.bandH = (shape == .expanded || (shape == .collapsed && atRest)) ? notchH : notchH + 8
        let (l, r) = wings()
        c.left = l; c.right = r

        // timer pieces
        let timeText = timer.text()
        setText(c.wingTime, timeText)
        setText(c.tTime, timeText)
        setText(c.tLabel, timer.mode == .stopwatch ? "스톱워치" : "타이머")
        setSymbol(c.pauseB, timer.running ? "pause.fill" : "play.fill", 20)

        // banner
        if let bn = banner {
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

        // alert
        setText(c.alertL, alertText ?? "")

        // media pieces
        if let m = media {
            setText(c.titleL, m.title)
            setText(c.artistL, m.artist)
            c.art.setImage(artwork); c.wingArt.setImage(artwork)
            let e = m.elapsedNow
            setText(c.elapsedL, mmss(e))
            setText(c.remainL, m.duration > 0 ? "-" + mmss(m.duration - e) : "")
            c.progress.fraction = m.duration > 0 ? CGFloat(e / m.duration) : 0
            c.progress.isHidden = m.duration <= 0
            setSymbol(c.playB, m.playing ? "pause.fill" : "play.fill", 30)
            for eq in [c.wingEq, c.bodyEq] { eq.color = artColor; eq.setPlaying(m.playing) }
        }

        c.needsLayout = true
        c.applyVisibility(expanded: shape == .expanded)
    }

    func desiredShape() -> Shape {
        if pinned && !liveActivity && !forceOpen { pinned = false }   // nothing left to show
        if forceOpen || pinned { return .expanded }
        if pressing || Date() < popUntil { return .pressed }
        if Date() < hoverUntil { return .peek }       // hovering only nudges it; a long press opens it
        if media != nil || timer.started { return .activity }
        return .collapsed
    }

    func applyShape() {
        let target = desiredShape()
        if target != shape {
            if target == .peek && shape != .pressed { haptic(.alignment) }   // light tick when the pointer arrives
            shape = target
            refreshUI()                                // wings/body change with the shape
            switch target {
            case .pressed:  stiffness = 900; damping = 48     // snaps to the finger
            case .peek:     stiffness = 600; damping = 40
            case .expanded: stiffness = 380; damping = 21     // gentle overshoot: the "pop"
            case .collapsed: stiffness = 90; damping = 19     // activity ended: glides in slowly (~0.7s), no bounce
            default:        stiffness = 420; damping = 36     // settles back without bouncing
            }
        }
        let size = frame(for: shape).size
        if abs(size.width - tgtW) > 0.01 || abs(size.height - tgtH) > 0.01 {
            tgtW = size.width; tgtH = size.height
            atRest = false
            link?.isPaused = false
        }
    }

    @objc func animTick(_ l: CADisplayLink) {
        let dt = min(max(l.targetTimestamp - l.timestamp, 1.0 / 240), 1.0 / 30)
        let steps = Int((dt * 240).rounded(.up)); let h = dt / CGFloat(steps)
        for _ in 0..<steps {
            velW += (-stiffness * (curW - tgtW) - damping * velW) * h
            velH += (-stiffness * (curH - tgtH) - damping * velH) * h
            curW += velW * h; curH += velH * h
        }
        if curH < notchH { curH = notchH; if velH < 0 { velH = 0 } }          // never shrink above the notch
        if abs(curW - tgtW) < 0.1 && abs(curH - tgtH) < 0.1 && abs(velW) < 2 && abs(velH) < 2 {
            curW = tgtW; curH = tgtH; velW = 0; velH = 0; l.isPaused = true; atRest = true
        }
        panel.setFrame(NSRect(x: screen.frame.midX - curW / 2, y: screen.frame.maxY - curH, width: curW, height: curH), display: true)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
