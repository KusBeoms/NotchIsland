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
        // MARK: persistence (wall clock, because the hardware counter restarts with the Mac)
        let t0: TimeInterval = Date().timeIntervalSince1970 - 100_000      // the stored copy is checked against the real clock
        let sw = TimerSnapshot(isCountdown: false, running: true, target: 300, accumulated: 20, startedWall: t0)
        assert(sw.elapsed(at: t0 + 100) == 120 && sw.elapsed(at: t0 - 50) == 20)             // a clock set back never subtracts
        let paused = TimerSnapshot(isCountdown: false, running: false, target: 300, accumulated: 42, startedWall: nil)
        assert(paused.elapsed(at: t0 + 99999) == 42)
        let cd = TimerSnapshot(isCountdown: true, running: true, target: 600, accumulated: 0, startedWall: t0)
        assert(!cd.isFinished(at: t0 + 599) && cd.isFinished(at: t0 + 600))
        // a running stopwatch resumes where the wall clock says
        let m1 = TimerModel()
        assert(!m1.restore(sw, wallNow: t0 + 100) && m1.running && m1.mode == .stopwatch && abs(m1.elapsed - 120) < 1)
        // a paused countdown keeps its remaining time
        let m2 = TimerModel()
        assert(!m2.restore(TimerSnapshot(isCountdown: true, running: false, target: 600, accumulated: 100, startedWall: nil)))
        assert(!m2.running && m2.started && m2.display == 500 && m2.mode == .countdown)
        // a countdown that ran out while the app was away: finished, stopped, showing 00:00; its Pomodoro set ends
        let m3 = TimerModel()
        let over = TimerSnapshot(isCountdown: true, running: true, target: 600, accumulated: 0, startedWall: t0,
                                 pomodoroPhase: "work", pomodoroCycle: 2, pomodoroConfig: [10, 5, 15, 4])
        assert(m3.restore(over, wallNow: t0 + 5000) && !m3.running && m3.finished && m3.display == 0 && m3.started)
        // a Pomodoro that is still going keeps its phase, cycle and lengths
        let m4 = TimerModel()
        assert(!m4.restore(over, wallNow: t0 + 100) && m4.running && m4.pomodoro?.phase == .work && m4.pomodoro?.cycle == 2)
        assert(m4.pomodoro?.config == PomodoroConfig(work: 10, rest: 5, longRest: 15, longEvery: 4))
        // snapshot -> restore round trip (same moment)
        let src = TimerModel(); src.startCountdown(minutes: 5)
        let snap = src.snapshot(wallNow: t0)!
        let dst = TimerModel(); dst.restore(snap, wallNow: t0 + 60)
        assert(dst.running && abs(dst.display - 240) < 1)
        assert(TimerModel().snapshot() == nil)                                                 // nothing counting: nothing stored
        // storage: encodes, decodes, and garbage is ignored
        let suite = UserDefaults(suiteName: "ni-timer-test-\(getpid())")!
        defer { suite.removePersistentDomain(forName: "ni-timer-test-\(getpid())") }
        TimerSnapshot.save(snap, to: suite)
        assert(TimerSnapshot.load(suite) == snap)
        suite.set(Data("nope".utf8), forKey: TimerSnapshot.key)
        assert(TimerSnapshot.load(suite) == nil)
        var bad = snap; bad.target = -5
        TimerSnapshot.save(bad, to: suite)
        assert(TimerSnapshot.load(suite) == nil)
        TimerSnapshot.save(nil, to: suite)
        assert(suite.data(forKey: TimerSnapshot.key) == nil)
        // jitter in the start time is not a change; a toggle is
        var jitter = snap; jitter.startedWall = snap.startedWall! + 0.4
        assert(snap.sameState(as: jitter))
        var toggled = snap; toggled.running = false
        assert(!snap.sameState(as: toggled))

        // extreme stored values never crash and are refused
        for bad in [1e300, -1e300, Double.nan, Double.infinity, -Double.infinity] {
            var x = snap; x.target = bad
            var y = snap; y.accumulated = bad
            var z = snap; z.startedWall = bad
            assert(!x.isSane(wallNow: t0) && !y.isSane(wallNow: t0) && !z.isSane(wallNow: t0))
            assert(!TimerModel().restore(x, wallNow: t0) && !TimerModel().restore(y, wallNow: t0) && !TimerModel().restore(z, wallNow: t0))
            assert(TimerModel.format(bad, roundUp: true).count >= 5 && TimerModel.format(bad, roundUp: false).count >= 5)
            assert(mmss(bad).contains(":"))
        }
        var old = snap; old.startedWall = t0 - 400 * 24 * 3600
        assert(!old.isSane(wallNow: t0))                                                           // a start older than a year
        var future = snap; future.startedWall = t0 + 3600
        assert(!future.isSane(wallNow: t0))                                                        // an hour in the future
        var skew = snap; skew.startedWall = t0 + 30
        assert(skew.isSane(wallNow: t0))                                                           // a clock a little behind is fine
        var longRun = snap; longRun.accumulated = TimerSnapshot.maxElapsed + 1
        assert(!longRun.isSane(wallNow: t0))
        var hugeTarget = snap; hugeTarget.target = TimerSnapshot.maxTarget + 1
        assert(!hugeTarget.isSane(wallNow: t0))
        var noStart = snap; noStart.startedWall = nil
        assert(noStart.running && !noStart.isSane(wallNow: t0))                                    // "running" with no start time
        assert(snap.elapsed(at: t0 + 1e12) <= TimerSnapshot.maxElapsed)
        // an already finished copy is restored as finished but never announced again (only "ran out while away" is news)
        let stoppedDone = TimerSnapshot(isCountdown: true, running: false, target: 60, accumulated: 60, startedWall: nil,
                                        pomodoroPhase: "work", pomodoroCycle: 1, pomodoroConfig: [25, 5, 15, 4])
        let m5 = TimerModel()
        assert(!m5.restore(stoppedDone, wallNow: t0) && m5.finished && !m5.running && m5.pomodoro == nil)
        let m6 = TimerModel()
        let ranOut = TimerSnapshot(isCountdown: true, running: true, target: 60, accumulated: 0, startedWall: t0)
        assert(m6.restore(ranOut, wallNow: t0 + 90) && m6.finished)                                // news, once ...
        assert(!TimerModel().restore(m6.snapshot(wallNow: t0 + 90)!, wallNow: t0 + 5000))          // ... its stopped copy is not news again

        print("Pomodoro transition and timer model checks passed")
    }
}
