import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - The main loop: its timer and the periodic work done on every tick.

extension App {
    /// The main loop runs at 60Hz only while something is on screen or moving; when the island rests it drops to 30Hz
    /// (the light sensor's own rate), with a little tolerance so the system can coalesce the wakeups.
    func scheduleStep(busy: Bool, deep: Bool = false) {
        stepTimer?.invalidate()
        stepBusy = busy
        stepDeep = deep && !busy
        let rate: StepRate = busy ? .full : (stepDeep ? .deepIdle : .idle)
        let t = Timer(timeInterval: rate.interval, repeats: true) { [weak self] _ in self?.step() }
        t.tolerance = busy ? 0.002 : 0.006
        RunLoop.main.add(t, forMode: .common)       // .common: also runs while a menu is open or a drag is in progress
        stepTimer = t
    }

    /// Something is visible, moving, pressed or dragged: needs the full frame rate.
    var stepNeedsFullRate: Bool {
        if islandSuppressed { return false }          // hidden: nothing moves on screen
        // a locked island that rests with nothing playing or counting needs no more than the idle rate
        let restingLocked = locked && shape == .expanded && atRest && media?.playing != true && !timer.running
        let lyricsMoving = lyricsVisible && c.lyricsPane.needsAdvance(at: lyricsPlaybackTime, playing: media?.playing ?? false)
        return lyricsMoving || (shape != .collapsed && !restingLocked) || !atRest || hudActive || pressing || dragActive || dropping || scrollHolding || alertText != nil || banner != nil
    }

    // MARK: periodic work

    /// True (and re-arms `last`) when `every` seconds have passed since it last was.
    func due(_ last: inout Double, _ every: Double) -> Bool {
        let n = CFAbsoluteTimeGetCurrent()
        guard n - last >= every else { return false }
        last = n; return true
    }

    /// Asks the window server whether Mission Control is up (see `MissionControlPolling` for when that is worth doing).
    func checkMissionControl(forced: Bool) {
        let visible = !acts.isEmpty || shape != .collapsed || pinned || locked
        let n = CFAbsoluteTimeGetCurrent()
        guard MissionControlPolling.shouldCheck(islandVisible: visible, missionControlUp: missionControl, sinceLast: n - tMission, forced: forced) else { return }
        tMission = n
        let mc = App.missionControlUp(on: screen)
        guard mc != missionControl else { return }
        missionControl = mc
        if mc { cancelPress() }                      // a press that began before it must not finish behind it (also stops the long-press timer)
        refreshUI()
    }

    /// Runs `show` now when the user has been idle for a moment and no other alert is on screen, otherwise queues it (see `AlertTiming`).
    /// `show` looks at the state again when it runs (the thing it announces may be gone by then) and returns false to be dropped
    /// without showing anything.
    func whenQuiet(_ show: @escaping () -> Bool) {
        if deferredAlerts.isEmpty, !alertOnScreen, !islandSuppressed, AlertTiming.shouldShow(secondsSinceInput: inputIdleSeconds(), waited: 0) { _ = show() }
        else {
            deferredAlerts.append((Date(), show))
            if deferredAlerts.count > 5 { deferredAlerts.removeFirst(deferredAlerts.count - 5) }      // only the latest few matter
        }
    }

    /// The alert sound. It is kept while mirroring unless the user chose to mute it there (a presentation).
    func beep() {
        if mirrorHidden && Settings.muteWhenMirroring { return }
        NSSound.beep()
    }

    var alertOnScreen: Bool { alertText != nil && Date() < alertUntil }

    /// At most one queued alert per pass, in order, and only once the previous one has gone from the screen.
    func runDeferredAlerts() {
        guard !deferredAlerts.isEmpty, !alertOnScreen, !islandSuppressed else { return }       // queued alerts wait for the island to come back
        let idle = inputIdleSeconds(), now = Date()
        while let first = deferredAlerts.first {
            guard AlertTiming.shouldShow(secondsSinceInput: idle, waited: now.timeIntervalSince(first.since)) else { return }
            deferredAlerts.removeFirst()
            if first.run() { return }                  // shown: the rest waits for it to end (stale ones are skipped on the spot)
        }
    }

    func step() {
        tick += 1
        let now = Date()

        // hover: pointer inside the current shape (a little padded) nudges the island
        let m = NSEvent.mouseLocation
        let pad: CGFloat = shape == .expanded ? 8 : 4
        let hit = frame(for: shape).insetBy(dx: -pad, dy: -pad)
        let probe = NSRect(x: hit.minX, y: hit.minY, width: hit.width, height: hit.height + 4) // include the screen's top edge
        if probe.contains(m) && !islandSuppressed { hoverLeftAt = nil }
        else if hoverEnteredAt != nil {                // leaving counts only after a short grace, so a jittery edge does not restart the wait
            if hoverLeftAt == nil { hoverLeftAt = now }
            if islandSuppressed || HoverDwell.hasLeft(leftAt: hoverLeftAt ?? now, now: now) { hoverEnteredAt = nil; hoverLeftAt = nil }
        }
        if probe.contains(m) && !islandSuppressed {
            if hoverEnteredAt == nil { hoverEnteredAt = now }
            if HoverDwell.met(enteredAt: hoverEnteredAt ?? now, now: now, alreadyOpen: shape != .collapsed && shape != .activity) {
                hoverUntil = now.addingTimeInterval(0.25)
            }
            if case .airpods? = banner, let expires = bannerHideAt { bannerHideAt = max(expires, now.addingTimeInterval(1.2)) }
            if hudActive { hudUntil = max(hudUntil, now.addingTimeInterval(0.9)) }   // pointer on the HUD: keep it
        }
        let overHUD = hudActive && probe.contains(m)
        if c.hBar.sliderMode != overHUD { c.hBar.sliderMode = overHUD }              // cells melt into a slider under the pointer

        if due(&tLockCheck, 5) { applyLockState() }        // the lock notices are only hints: re-ask the session now and then
        if due(&tSensorConfig, 1) { sensorEnabled = SensorGestureMap(Settings.sensorGestureMap).anyGestureEnabled }
        if !sensorEnabled || islandSuppressed {
            // every gesture is off: nothing to read the light for. Whatever was in progress is dropped without acting, and the
            // averages start from scratch when the sensor is wanted again (an old "base" would read the room as a cover).
            if sensorWasOn { sensorWasOn = false; resetSensorState() }
        } else if !stepBusy || tick % 2 == 0 {     // 30Hz (20Hz in deep idle) in both modes: the ambient light sensor is the touch sensor
            sensorWasOn = true
            let clock = CFAbsoluteTimeGetCurrent()
            sensorDt = lastSensorSample > 0 ? min(0.25, clock - lastSensorSample) : 0
            lastSensorSample = clock
            let v = simLux ?? als_read()              // simLux is only set by the test hook below
            if v >= 0 { lux = v; lastSensorReading = clock }     // raw value, no smoothing; hysteresis below prevents flicker
            else if SensorSmoothing.isStale(silentFor: clock - lastSensorReading) { lux = -1 }   // ~2s of silence: stop trusting old data
            let wasCovered = darkLatched
            if simLux == nil, lux >= 0 { trackSuddenDark(lux, now) }
            // in a dim room covering the sensor hardly changes the reading: the bar follows the room's own light (but never above `threshold`)
            let thr = max(2, ambient > 0 ? min(threshold, ambient * 0.3) : threshold)
            if (lux >= 0 && lux < thr) || dropSince != nil { darkLatched = true }   // covered  = finger down (a drop to under 40% of the light counts, even if it reads 80)
            else if lux < 0 || lux > thr * 1.2 { darkLatched = false }       // uncovered = finger up
            if !darkLatched && lux >= 0 { ambient = ambient < 0 ? lux : SensorSmoothing.blend(ambient, lux, dt: sensorDt) }
            if darkLatched && !wasCovered { sensorTouchBegan() }
            else if !darkLatched && wasCovered { sensorTouchEnded() }
            if StepRatePolicy.sensorActive(lux: lux, threshold: thr, ambient: ambient, covered: darkLatched, dropInProgress: dropSince != nil, gestureBusy: !sensorRecognizer.isIdle) {
                sensorActiveAt = CFAbsoluteTimeGetCurrent()
            }
        }
        sensorTick()                                  // a long cover or a waiting tap matures with time, not with a light change
        if let t = bannerHideAt, now > t {                      // a timed banner (AirPods connecting) goes away by itself
            bannerHideAt = nil
            banner = nil; if selected == nil && alertText == nil { pinned = false }
        }
        if alertText != nil && now >= alertUntil {
            alertText = nil
            if selected == nil && banner == nil { pinned = false }
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
        if due(&tFiles, 5) { fileInfo.removeAll(); c.fileShown = nil }
        if due(&tVolume, 2) { pollVolume() }       // safety net only: volume changes normally arrive as events (watchVolume)
        if lyricsVisible {
            lyrics.refreshIfNeeded()
            let time = lyricsPlaybackTime
            let playing = media?.playing ?? false
            if c.lyricsPane.needsAdvance(at: time, playing: playing) {
                c.lyricsPane.advance(to: time, playing: playing)
            }   // Keep presentation frames alive until paused motion has settled.
        }
        if due(&tBattery, 5) { pollBattery() }     // safety net; battery changes normally arrive from IOKit (watchBattery)
        // each lookup spawns osascript: poll faster only while a track is playing or the card is open
        if due(&tMusic, shape == .expanded ? 2 : (media?.playing == true ? 3 : 5)) { pollMusic() }
        if let m = media, !m.playing, !demoMedia, demoActsN == nil, shape != .expanded,
           now.timeIntervalSince(lastPlayingAt) > 4 { media = nil }     // paused for a while: let it go
        checkMissionControl(forced: false)
        if due(&tCalendar, 15) { pollCalendar() }  // an event becomes an activity (or its alert is due) as time passes, with nothing else happening
        if due(&tAirPods, 12) { pollAirPods() }    // system_profiler is heavy; a new output device triggers it sooner (see watchOutputDevice)

        
        if due(&tTimerSave, 1) { saveTimerIfChanged() }
        runDeferredAlerts()
        prevTimerStarted = timer.started
        if timer.running && timer.finished {
            if let phase = timer.advancePomodoro() {
                // A Pomodoro never stops by itself: the next phase is already running. A short alert tells you, without
                // taking over the card (the alert closes on its own).
                beep()
                whenQuiet { [weak self] in
                    guard let s = self, s.timer.running, s.timer.pomodoro == phase else { return false }     // the set moved on or was stopped
                    s.showAlert(phase.announcement, seconds: 4); return true
                }
                refreshUI()
            } else {
                timer.toggle() // Keep the completed activity until it is dismissed or restarted.
                beep(); haptic(.levelChange)
                whenQuiet { [weak self] in                // the island does not jump open under the user's hands
                    guard let s = self, s.timer.finished, !s.timer.running else { return false }          // restarted or cancelled meanwhile
                    s.selected = .timer; s.pinned = true; s.refreshUI(); return true
                }
                refreshUI()
            }
        }

        if !liveActivity && shape == .collapsed && atRest && !pinned && !stepBusy {
            if !idleRefreshed { idleRefreshed = true; refreshUI() }     // resting and empty: one last refresh, then nothing to redraw
        } else {
            idleRefreshed = false
            if tick % (stepBusy ? 6 : 3) == 0 { refreshUI() }           // content at 10Hz; shape/hover/press every frame
        }
        applyShape()
        if !sensorRecognizer.isIdle { sensorActiveAt = CFAbsoluteTimeGetCurrent() }      // a tap still waiting for its partner keeps the sampling up
        let wantFull = stepNeedsFullRate
        let restingCollapsed = !liveActivity && shape == .collapsed && atRest && !pinned
        let want = StepRatePolicy.rate(needsFull: wantFull, restingCollapsed: restingCollapsed, sinceSensorActivity: CFAbsoluteTimeGetCurrent() - sensorActiveAt)
        if wantFull != stepBusy || (!wantFull && (want == .deepIdle) != stepDeep) { scheduleStep(busy: wantFull, deep: want == .deepIdle) }
    }
}
