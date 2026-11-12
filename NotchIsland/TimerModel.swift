import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

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

