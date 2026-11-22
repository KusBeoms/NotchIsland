import Foundation

@main
struct StepRateTests {
    typealias P = StepRatePolicy

    static func main() {
        // visible / moving work always runs flat out
        assert(P.rate(needsFull: true, restingCollapsed: true, sinceSensorActivity: 100) == .full)
        // resting and quiet: deep idle; a recent finger-like reading keeps the normal idle rate
        assert(P.rate(needsFull: false, restingCollapsed: true, sinceSensorActivity: 5) == .deepIdle)
        assert(P.rate(needsFull: false, restingCollapsed: true, sinceSensorActivity: 0.5) == .idle)
        assert(P.rate(needsFull: false, restingCollapsed: false, sinceSensorActivity: 100) == .idle)    // e.g. a live activity
        // the active window covers a double tap and a hold with room to spare, and deep idle still samples every 50 ms
        assert(P.activeHold > SensorGestureRecognizer.doubleTapWindow + SensorGestureRecognizer.holdDelay(.openMusic))
        assert(StepRate.deepIdle.interval <= 0.05 && StepRate.idle.interval < StepRate.deepIdle.interval && StepRate.full.interval < StepRate.idle.interval)

        // what counts as sensor activity
        assert(!P.sensorActive(lux: 400, threshold: 50, ambient: 400, covered: false, dropInProgress: false, gestureBusy: false))
        assert(P.sensorActive(lux: 60, threshold: 50, ambient: 400, covered: false, dropInProgress: false, gestureBusy: false))    // near the bar
        assert(P.sensorActive(lux: 250, threshold: 50, ambient: 400, covered: false, dropInProgress: false, gestureBusy: false))   // a dip
        assert(P.sensorActive(lux: 400, threshold: 50, ambient: 400, covered: true, dropInProgress: false, gestureBusy: false))
        assert(P.sensorActive(lux: 400, threshold: 50, ambient: 400, covered: false, dropInProgress: true, gestureBusy: false))
        assert(P.sensorActive(lux: 400, threshold: 50, ambient: 400, covered: false, dropInProgress: false, gestureBusy: true))
        assert(!P.sensorActive(lux: -1, threshold: 50, ambient: -1, covered: false, dropInProgress: false, gestureBusy: false))     // no sensor: nothing to see

        // the sensor is polled unless every gesture is switched off
        assert(SensorGestureMap().anyGestureEnabled)
        var off: [String: String] = [:]
        for c in SensorContext.allCases { for g in SensorGesture.allCases { off[SensorGestureMap.key(c, g)] = SensorAction.none.rawValue } }
        assert(!SensorGestureMap(off).anyGestureEnabled)
        off[SensorGestureMap.key(.openOther, .doubleTap)] = SensorAction.playPause.rawValue
        assert(SensorGestureMap(off).anyGestureEnabled)

        // a dark room can rest: relative to its own light, not to the touch bar
        assert(!P.sensorActive(lux: 20, threshold: 50, ambient: 20, covered: false, dropInProgress: false, gestureBusy: false))
        assert(P.sensorActive(lux: 10, threshold: 50, ambient: 20, covered: false, dropInProgress: false, gestureBusy: false))
        assert(P.sensorActive(lux: 60, threshold: 50, ambient: -1, covered: false, dropInProgress: false, gestureBusy: false))     // light unknown yet

        // smoothing follows the clock: 30 samples at 1/30 s == 20 samples at 1/20 s == one 1 s step
        func run(_ n: Int, _ dt: Double) -> Double { var v = 100.0; for _ in 0..<n { v = SensorSmoothing.blend(v, 0, dt: dt) }; return v }
        assert(abs(run(30, 1.0 / 30) - run(20, 1.0 / 20)) < 1e-9 && abs(run(30, 1.0 / 30) - run(1, 1.0)) < 1e-9)
        assert(SensorSmoothing.blend(50, 50, dt: 0.05) == 50 && SensorSmoothing.blend(10, 90, dt: 0) == 10)
        assert(!SensorSmoothing.isStale(silentFor: 1.9) && SensorSmoothing.isStale(silentFor: 2))

        // Mission Control: nothing visible and not in MC -> never asked; otherwise at most every 0.5 s, a space change at once
        typealias M = MissionControlPolling
        assert(M.visibleInterval <= 0.2 && M.hiddenInterval >= 0.5)
        assert(!M.shouldCheck(islandVisible: false, missionControlUp: false, sinceLast: 10, forced: true))      // nothing to fold: never asked
        assert(!M.shouldCheck(islandVisible: true, missionControlUp: false, sinceLast: 0.1, forced: false))
        assert(M.shouldCheck(islandVisible: true, missionControlUp: false, sinceLast: 0.2, forced: false))      // visible: prompt
        assert(!M.shouldCheck(islandVisible: false, missionControlUp: true, sinceLast: 0.3, forced: false))     // hidden: slow
        assert(M.shouldCheck(islandVisible: false, missionControlUp: true, sinceLast: 0.5, forced: false))
        assert(M.shouldCheck(islandVisible: true, missionControlUp: false, sinceLast: 0.01, forced: true))
        assert(M.shouldCheck(islandVisible: false, missionControlUp: true, sinceLast: 0.6, forced: false))      // keep watching for its end

        // system-started alerts wait for a quiet moment, but not forever
        assert(AlertTiming.shouldShow(secondsSinceInput: 3, waited: 0) && AlertTiming.shouldShow(secondsSinceInput: 100, waited: 0))
        assert(!AlertTiming.shouldShow(secondsSinceInput: 0.5, waited: 5))
        assert(AlertTiming.shouldShow(secondsSinceInput: 0.1, waited: AlertTiming.maxWait))

        // mirroring: only a mirrored built-in (notch) display hides the island
        func d(_ id: UInt32, builtin: Bool = false, set: Bool = false, mirrors: UInt32 = 0) -> DisplayMirrorInfo {
            DisplayMirrorInfo(id: id, isBuiltin: builtin, inMirrorSet: set, mirrorsDisplay: mirrors)
        }
        assert(!MirrorPolicy.shouldHide([d(1, builtin: true), d(2)], enabled: true))                          // two screens, no mirroring
        assert(!MirrorPolicy.shouldHide([d(1, builtin: true)], enabled: true))
        assert(MirrorPolicy.shouldHide([d(1, builtin: true, set: true), d(2, set: true, mirrors: 1)], enabled: true))   // built-in is the master
        assert(MirrorPolicy.shouldHide([d(1, builtin: true, set: true, mirrors: 2), d(2, set: true)], enabled: true))   // built-in is the slave
        assert(!MirrorPolicy.shouldHide([d(2), d(3, set: true, mirrors: 2), d(1, builtin: true)], enabled: true))       // two externals mirror each other
        assert(!MirrorPolicy.shouldHide([d(2)], enabled: true))                                                         // external only (lid closed)
        assert(!MirrorPolicy.shouldHide([d(1, builtin: true, set: true), d(2, set: true, mirrors: 1)], enabled: false)) // the user turned it off
        assert(!MirrorPolicy.shouldHide([], enabled: true))

        let entered = Date()
        assert(!HoverDwell.met(enteredAt: entered, now: entered.addingTimeInterval(0.05), alreadyOpen: false))
        assert(HoverDwell.met(enteredAt: entered, now: entered.addingTimeInterval(0.12), alreadyOpen: false))
        assert(HoverDwell.met(enteredAt: entered, now: entered, alreadyOpen: true))

        assert(!HoverDwell.hasLeft(leftAt: entered, now: entered.addingTimeInterval(0.05)) && HoverDwell.hasLeft(leftAt: entered, now: entered.addingTimeInterval(0.08)))
        assert(MirrorPolicy.nextHidden(previous: true, displays: nil, enabled: true))                      // unreadable list: keep the state
        assert(!MirrorPolicy.nextHidden(previous: false, displays: [], enabled: true))
        assert(MirrorPolicy.nextHidden(previous: false, displays: [d(1, builtin: true, set: true)], enabled: true))
        assert(!MirrorPolicy.nextHidden(previous: true, displays: [d(1, builtin: true)], enabled: true))

        // login item
        typealias L = LoginItemPolicy
        assert(L.checkbox(status: .notRegistered, agentPlistExists: false) == (false, true, nil))
        assert(L.checkbox(status: .enabled, agentPlistExists: false) == (true, true, nil))
        assert(L.checkbox(status: .requiresApproval, agentPlistExists: false).note != nil && L.checkbox(status: .requiresApproval, agentPlistExists: false).on)
        let agent = L.checkbox(status: .notRegistered, agentPlistExists: true)
        assert(!agent.enabled && agent.on && agent.note?.contains("install.sh") == true)                  // install.sh's agent: the box is off limits
        assert(L.shouldUnregister(.enabled) && L.shouldUnregister(.requiresApproval) && !L.shouldUnregister(.notRegistered) && !L.shouldUnregister(.notFound))
        assert(L.needsApproval(afterRegister: .requiresApproval) && !L.needsApproval(afterRegister: .enabled))
        assert(L.registered(.enabled) && !L.registered(.notRegistered))

        // text clipping
        assert(TextClip.tail("short", limit: 10) == "short" && TextClip.tail("", limit: 10) == "")
        assert(TextClip.tail("abcdefghij", limit: 5) == "abcd…" && TextClip.tail("abcd efgh", limit: 6) == "abcd…")
        assert(TextClip.tail("가나다라마바사", limit: 4) == "가나다…")
        assert(TextClip.tail(String(repeating: "👍🏽", count: 50), limit: 5).count == 5)                      // composed characters stay whole
        assert(TextClip.middle("report.pdf", limit: 20) == "report.pdf")
        let clipped = TextClip.middle("a very long file name for a quarterly report.pdf", limit: 24)
        assert(clipped.count == 24 && clipped.hasSuffix(".pdf") && clipped.contains("…") && clipped.hasPrefix("a very"))
        assert(TextClip.middle("no_extension_but_a_very_long_name_indeed", limit: 16).count == 16)
        assert(TextClip.middle(".hiddenfilewithaverylongname", limit: 12).count <= 12)
        assert(TextClip.middle("archive.verylongextension_here", limit: 12).count == 12)                   // not an extension worth keeping
        assert(TextClip.middle("x.pdf", limit: 3) == "x.pdf" || TextClip.middle("x.pdf", limit: 3).count <= 3)
        assert(TextClip.middle("가나다라마바사아자차카타파하.hwp", limit: 10).hasSuffix(".hwp"))

        print("Step rate checks passed")
    }
}
