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

    /// nil while nothing is counting (a fresh or reset timer).
    func snapshot(wallNow: TimeInterval = Date().timeIntervalSince1970) -> TimerSnapshot? {
        guard started else { return nil }
        let phase: String? = pomodoro.map { $0.phase == .work ? "work" : $0.phase == .rest ? "rest" : "longRest" }
        let cfg = pomodoro?.config ?? PomodoroConfig()
        let sinceStart = running ? max(0, hardwareSeconds() - (startedAt ?? hardwareSeconds())) : 0
        return TimerSnapshot(isCountdown: mode == .countdown, running: running, target: target, accumulated: accumulated,
                             startedWall: running ? wallNow - sinceStart : nil, pomodoroPhase: phase,
                             pomodoroCycle: pomodoro?.cycle ?? 1, pomodoroConfig: [cfg.work, cfg.rest, cfg.longRest, cfg.longEvery])
    }

    /// Puts a stored timer back. Returns true when it ran out while the app was away (it was running when stored): a countdown that is over
    /// comes back as a finished one (stopped, showing 00:00), never as a running one, and its Pomodoro set ends.
    @discardableResult
    func restore(_ s: TimerSnapshot, wallNow: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard s.isSane(wallNow: wallNow) else { return false }
        reset()
        mode = s.isCountdown ? .countdown : .stopwatch
        target = s.target
        let elapsed = s.elapsed(at: wallNow)
        if s.isFinished(at: wallNow) {
            accumulated = max(elapsed, target); running = false; startedAt = nil
            return s.running                           // news only when it ran out while away; a copy that was already finished is not announced again
        }
        accumulated = elapsed
        if s.running { running = true; startedAt = hardwareSeconds() } else { running = false; startedAt = nil }
        if s.isCountdown, let phase = s.pomodoroPhase {
            let c = s.pomodoroConfig
            var set = PomodoroState(config: PomodoroConfig(work: c[0], rest: c[1], longRest: c[2], longEvery: c[3]))
            set.phase = phase == "rest" ? .rest : phase == "longRest" ? .longRest : .work
            set.cycle = min(max(1, s.pomodoroCycle), c[3])
            pomodoro = set
        }
        return false
    }

    static func format(_ t: TimeInterval, roundUp: Bool) -> String {
        let s = Int((t.isFinite ? min(max(t, 0), 1e9) : 0).rounded(roundUp ? .up : .down))     // never traps on a huge or NaN value
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
    func text() -> String { TimerModel.format(display, roundUp: mode == .countdown) }
}

// MARK: - Surviving a restart

/// What is written to the preferences so a timer or stopwatch outlives the app (a quit, a crash, an update restart).
/// The hardware counter restarts with the Mac, so across launches the wall clock is the only reference: a running timer
/// keeps the wall-clock time it was started at. Pure value type: restoring is tested without clocks or files.
struct TimerSnapshot: Codable, Equatable {
    var isCountdown: Bool
    var running: Bool
    var target: TimeInterval
    var accumulated: TimeInterval          // time counted before the current run (all of it while paused)
    var startedWall: TimeInterval?         // epoch seconds when the current run began (nil while paused)
    var pomodoroPhase: String?             // "work" / "rest" / "longRest"; nil = no Pomodoro set
    var pomodoroCycle = 1
    var pomodoroConfig = [25, 5, 15, 4]    // work, rest, longRest, longEvery

    /// Counted time at `wallNow`. A clock that moved backwards never subtracts time.
    func elapsed(at wallNow: TimeInterval) -> TimeInterval {
        min(Self.maxElapsed, accumulated + (running ? max(0, wallNow - (startedWall ?? wallNow)) : 0))
    }
    func isFinished(at wallNow: TimeInterval) -> Bool { isCountdown && elapsed(at: wallNow) >= target }

    static let maxTarget: TimeInterval = 100 * 3600                // a countdown of more than 100 hours is not a real one
    static let maxElapsed: TimeInterval = 100 * 24 * 3600          // nor is a stopwatch that ran for more than 100 days

    /// Values a real timer can hold; anything else in the preferences is ignored. `wallNow` bounds the start time: it
    /// cannot be older than a year, nor (beyond a clock adjustment) in the future.
    func isSane(wallNow: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard target.isFinite, accumulated.isFinite, accumulated >= 0, accumulated <= Self.maxElapsed,
              target > 0, target <= Self.maxTarget,
              pomodoroConfig.count == 4, pomodoroConfig.allSatisfy({ $0 >= 1 && $0 <= 600 }) else { return false }
        if let w = startedWall {
            guard w.isFinite, w >= wallNow - 366 * 24 * 3600, w <= wallNow + 600 else { return false }
        } else if running { return false }                         // a running timer without a start time cannot be resumed
        return true
    }

    /// Equal apart from the start time's float jitter: decides whether the stored copy is out of date.
    func sameState(as other: TimerSnapshot) -> Bool {
        var a = self, b = other
        if let x = a.startedWall, let y = b.startedWall, abs(x - y) < 2 { a.startedWall = y }
        return a == b
    }

    static let key = "timerSnapshot"
    static func load(_ store: UserDefaults) -> TimerSnapshot? {
        guard let data = store.data(forKey: key), let s = try? JSONDecoder().decode(TimerSnapshot.self, from: data), s.isSane() else { return nil }
        return s
    }
    static func save(_ s: TimerSnapshot?, to store: UserDefaults) {
        if let s, let data = try? JSONEncoder().encode(s) { store.set(data, forKey: key) } else { store.removeObject(forKey: key) }
    }
}

func mmss(_ t: TimeInterval) -> String {
    let s = Int((t.isFinite ? min(max(t, 0), 1e9) : 0).rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}

