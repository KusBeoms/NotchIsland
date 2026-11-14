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
//   * Battery events       -> brief connection / 20% / 10% banners; no ongoing battery activity

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
