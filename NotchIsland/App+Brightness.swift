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
        lightBase = lightBase * 0.98 + lux * 0.02
        if now.timeIntervalSince(lastBrightnessRead) > 0.5 { lastBrightnessRead = now; lastBrightness = SystemLevels.brightness() ?? lastBrightness }
    }
    func releaseAutoBrightness() {
        guard autoBrightnessHeld || UserDefaults.standard.bool(forKey: Self.autoBrightnessHeldKey) else { return }
        autoBrightnessHeld = false
        if SystemLevels.setAutoBrightness(true) { UserDefaults.standard.removeObject(forKey: Self.autoBrightnessHeldKey) }
    }
    func applicationWillTerminate(_ n: Notification) { releaseAutoBrightness() }
}
