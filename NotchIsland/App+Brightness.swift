import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Holding the automatic brightness while the light sensor is covered; app termination.

extension App {
    func holdAutoBrightness() {
        guard !autoBrightnessHeld, SystemLevels.autoBrightness() == true else { return }
        UserDefaults.standard.set(true, forKey: Self.autoBrightnessHeldKey)   // survives a crash: restored at the next launch
        guard SystemLevels.setAutoBrightness(false) else { UserDefaults.standard.removeObject(forKey: Self.autoBrightnessHeldKey); return }
        autoBrightnessHeld = true
        if let keep = lastBrightness, let now = SystemLevels.brightness(), now < keep - 0.01 { SystemLevels.setBrightness(keep) }   // undo any dimming that started before the touch was seen
    }
    /// A finger on the sensor makes the light fall to a fraction of its old level within a frame or two (it rarely reads 0:
    /// 70-100 is common), whereas dusk moves the slow average along with it and is never seen as a drop.
    func trackSuddenDark(_ lux: Double, _ now: Date) {
        if lightBase < 0 { lightBase = lux }
        if let since = dropSince {
            if lux > lightBase * 0.7 {                                   // light is back: the finger lifted (0.3s debounce for a flickering cover)
                let from = recoveredSince ?? now; recoveredSince = from
                if now.timeIntervalSince(from) > 0.3 { dropSince = nil; recoveredSince = nil; releaseAutoBrightness() }
            } else {
                recoveredSince = nil
                if now.timeIntervalSince(since) > Self.realDarkAfter {   // dark for long: it is really dark, let macOS adapt and treat this as the new normal
                    dropSince = nil; lightBase = lux; releaseAutoBrightness()
                }
            }
            return
        }
        if lightBase > 30 && lux < lightBase * 0.4 {                     // sudden dark = a touch: keep macOS from dimming
            dropSince = now; recoveredSince = nil; holdAutoBrightness()
            return
        }
        lightBase = SensorSmoothing.blend(lightBase, lux, dt: sensorDt)
        if now.timeIntervalSince(lastBrightnessRead) > 0.5 { lastBrightnessRead = now; lastBrightness = SystemLevels.brightness() ?? lastBrightness }
    }
    /// The light sensor is no longer wanted: forget the cover that was in progress (no gesture runs), the averages, and the
    /// brightness hold.
    func resetSensorState() {
        lux = -1; darkLatched = false
        dropSince = nil; recoveredSince = nil
        lightBase = -1; ambient = -1
        lastSensorSample = 0; lastSensorReading = 0
        sensorRecognizer.cancel()                  // not `sensorTouchEnded()`: that would turn the lifted finger into a tap
        pressing = false
        releaseAutoBrightness()
    }
    func releaseAutoBrightness() {
        guard autoBrightnessHeld || UserDefaults.standard.bool(forKey: Self.autoBrightnessHeldKey) else { return }
        autoBrightnessHeld = false
        if SystemLevels.setAutoBrightness(true) { UserDefaults.standard.removeObject(forKey: Self.autoBrightnessHeldKey) }
    }
    func applicationWillTerminate(_ n: Notification) { releaseAutoBrightness(); saveTimerIfChanged(); unwatchMirroring() }

    // MARK: the timer outlives the app (see TimerSnapshot)

    /// Writes the timer to the preferences when it differs from what is stored. A running timer's snapshot only changes when the
    /// user acts on it, so this is cheap to call every second.
    func saveTimerIfChanged() {
        guard CommandLine.arguments.count == 1 else { return }            // demo / test runs never touch the saved timer
        let now = timer.snapshot()
        if let a = now, let b = savedTimer, a.sameState(as: b) { return }
        if now == nil && savedTimer == nil { return }
        savedTimer = now
        TimerSnapshot.save(now, to: Settings.store)
    }

    /// At launch: a timer that was counting comes back; one that ran out meanwhile comes back finished and says so.
    func restoreTimer() {
        guard CommandLine.arguments.count == 1, !demoTimer, let s = TimerSnapshot.load(Settings.store) else { return }
        savedTimer = s
        if timer.restore(s) {                          // true only when it ran out while the app was away (once: the stored copy is rewritten as stopped)
            let what = s.pomodoroPhase != nil ? "포모도로" : "타이머"
            whenQuiet { [weak self] in
                guard let s = self, s.timer.finished, !s.timer.running else { return false }
                s.showAlert("\(what)가 끝났습니다", seconds: 4); return true
            }
        }
    }
}
