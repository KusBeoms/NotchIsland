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

/// Lengths of a Pomodoro set, in minutes.
struct PomodoroConfig: Equatable {
    var work = 25
    var rest = 5
    var longRest = 15
    var longEvery = 4            // a long rest after this many work sessions
}

/// Where a running Pomodoro set is. Pure value type: the transition rules are tested without a clock.
struct PomodoroState: Equatable {
    enum Phase { case work, rest, longRest }
    var phase: Phase = .work
    var cycle = 1                // which work session of the set this is (or just was): 1...longEvery
    var config = PomodoroConfig()

    var duration: TimeInterval {
        switch phase {
        case .work: return TimeInterval(config.work * 60)
        case .rest: return TimeInterval(config.rest * 60)
        case .longRest: return TimeInterval(config.longRest * 60)
        }
    }
    var isBreak: Bool { phase != .work }

    /// Short state for the card: "집중 2/4", "휴식", "긴 휴식".
    var label: String {
        switch phase {
        case .work: return "집중 \(cycle)/\(config.longEvery)"
        case .rest: return "휴식"
        case .longRest: return "긴 휴식"
        }
    }
    /// What the alert says when this phase begins.
    var announcement: String {
        let minutes = Int(duration / 60)
        switch phase {
        case .work: return "집중 시작 \(minutes)분 (\(cycle)/\(config.longEvery))"
        case .rest: return "휴식 \(minutes)분"
        case .longRest: return "긴 휴식 \(minutes)분"
        }
    }

    /// The state right after the current phase ends: work -> rest (long after the last session of the set) -> work.
    var advanced: PomodoroState {
        var next = self
        switch phase {
        case .work: next.phase = cycle >= config.longEvery ? .longRest : .rest
        case .rest: next.phase = .work; next.cycle = cycle + 1
        case .longRest: next.phase = .work; next.cycle = 1
        }
        return next
    }
}

final class TimerModel {
    enum Mode { case stopwatch, countdown }
    var mode: Mode = .stopwatch
    var running = false
    var target: TimeInterval = 300       // countdown length
    private(set) var pomodoro: PomodoroState?     // set while a Pomodoro set runs; it is a countdown that renews itself
    private var accumulated: TimeInterval = 0
    private var startedAt: TimeInterval?     // hardwareSeconds() when it was last started

    var elapsed: TimeInterval { accumulated + (running ? hardwareSeconds() - (startedAt ?? hardwareSeconds()) : 0) }
    var display: TimeInterval { mode == .stopwatch ? elapsed : max(0, target - elapsed) }
    var finished: Bool { mode == .countdown && elapsed >= target }

    func toggle() {
        if running { accumulated = elapsed; running = false; startedAt = nil }
        else {
            if finished { let duration = target, set = pomodoro; reset(); target = duration; pomodoro = set }
            startedAt = hardwareSeconds(); running = true
        }
    }
    var started: Bool { running || accumulated > 0 }
    /// Any reset ends a Pomodoro set too; `toggle()` restarting a finished countdown is the one exception.
    func reset() { running = false; accumulated = 0; startedAt = nil; target = 300; pomodoro = nil }
    func startStopwatch() { reset(); mode = .stopwatch; toggle() }
    func startCountdown(minutes: Int) { reset(); mode = .countdown; target = TimeInterval(minutes * 60); toggle() }
    func switchMode() { reset(); mode = (mode == .stopwatch) ? .countdown : .stopwatch }
    func addMinute() { if mode == .countdown { target += 60 } }

    func startPomodoro(_ config: PomodoroConfig) {
        reset(); mode = .countdown
        let set = PomodoroState(config: config)
        pomodoro = set; target = set.duration
        toggle()
    }
    /// The running phase ended: begin the next one straight away. Returns it, or nil when no Pomodoro set is running.
    @discardableResult
    func advancePomodoro() -> PomodoroState? {
        guard let set = pomodoro?.advanced else { return nil }
        pomodoro = set; target = set.duration
        accumulated = 0; startedAt = hardwareSeconds(); running = true
        return set
    }

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

