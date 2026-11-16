import Foundation

// Pomodoro transition rules and how the timer model keeps (or ends) a set. No clock waiting needed.
@main
struct TimerTests {
    static func main() {
        // Default set: 25 / 5, a long 15 after the 4th session.
        var set = PomodoroState()
        assert(set.phase == .work && set.cycle == 1 && set.duration == 25 * 60 && !set.isBreak)
        set = set.advanced
        assert(set.phase == .rest && set.cycle == 1 && set.duration == 5 * 60 && set.isBreak)
        set = set.advanced
        assert(set.phase == .work && set.cycle == 2)
        set = set.advanced.advanced
        assert(set.phase == .work && set.cycle == 3)
        set = set.advanced.advanced
        assert(set.phase == .work && set.cycle == 4)
        set = set.advanced
        assert(set.phase == .longRest && set.cycle == 4 && set.duration == 15 * 60)
        set = set.advanced
        assert(set.phase == .work && set.cycle == 1)                // the set starts over

        // Texts shown on the card and in the alert.
        let fresh = PomodoroState()
        assert(fresh.label == "집중 1/4" && fresh.announcement == "집중 시작 25분 (1/4)")
        assert(fresh.advanced.label == "휴식" && fresh.advanced.announcement == "휴식 5분")
        assert(PomodoroState(phase: .longRest, cycle: 4).label == "긴 휴식")
        assert(PomodoroState(phase: .longRest, cycle: 4).announcement == "긴 휴식 15분")

        // Custom lengths: a long rest after every 2nd session.
        let custom = PomodoroConfig(work: 50, rest: 10, longRest: 30, longEvery: 2)
        var s2 = PomodoroState(config: custom)
        assert(s2.duration == 50 * 60)
        s2 = s2.advanced.advanced.advanced
        assert(s2.phase == .longRest && s2.duration == 30 * 60)

        // The model: a Pomodoro is a countdown that renews itself.
        let timer = TimerModel()
        timer.startPomodoro(PomodoroConfig())
        assert(timer.running && timer.mode == .countdown && timer.target == 25 * 60 && timer.pomodoro?.phase == .work)
        assert(!timer.finished)
        let next = timer.advancePomodoro()
        assert(next?.phase == .rest && timer.target == 5 * 60 && timer.running && timer.elapsed < 1)
        timer.advancePomodoro()
        assert(timer.pomodoro?.phase == .work && timer.pomodoro?.cycle == 2 && timer.target == 25 * 60)

        // Pausing and resuming keeps the set; only a reset or a plain timer ends it.
        timer.toggle()
        assert(!timer.running && timer.pomodoro != nil)
        timer.toggle()
        assert(timer.running && timer.pomodoro != nil)
        timer.reset()
        assert(timer.pomodoro == nil && !timer.started && timer.target == 300)
        timer.startPomodoro(PomodoroConfig())
        timer.startCountdown(minutes: 3)
        assert(timer.pomodoro == nil && timer.target == 180)
        timer.startPomodoro(PomodoroConfig())
        timer.startStopwatch()
        assert(timer.pomodoro == nil && timer.mode == .stopwatch)

        // advancePomodoro does nothing without a set.
        timer.reset()
        assert(timer.advancePomodoro() == nil && !timer.running)

        // "+1 minute" extends the running phase and leaves the set alone.
        let extended = TimerModel()
        extended.startPomodoro(PomodoroConfig(work: 1, rest: 1, longRest: 1, longEvery: 2))
        extended.addMinute()
        assert(extended.target == 120 && extended.pomodoro?.phase == .work)
        print("Pomodoro transition and timer model checks passed")
    }
}
