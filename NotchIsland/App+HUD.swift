import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Volume / brightness HUD, media keys, banners and alerts.

extension App {
    // MARK: volume / brightness HUD

    func showHUD(_ kind: LevelKind, _ value: Float, muted: Bool = false, seconds: TimeInterval = 1.8) {
        hudKind = kind; hudValue = value; hudMuted = muted
        hudUntil = Date().addingTimeInterval(seconds)
        refreshUI()
    }

    /// Volume changed by something else (menu bar slider, headphones, another app): show it too.
    func pollVolume() {
        guard let v = SystemLevels.volume() else { return }
        let muted = SystemLevels.muted() ?? false
        lastVol = v; lastMute = muted
        // Core Audio reports a value change, not whether a human or adaptive audio caused it.
        // Only refresh an existing HUD; new HUDs require an intercepted key or our slider.
        if hudActive && hudKind == .volume { hudValue = v; hudMuted = muted || v < 0.001 }
    }

    /// Media keys, once the Accessibility permission has been granted. Returns true when the key was handled.
    func handleMediaKey(_ code: Int, _ down: Bool, _ fine: Bool) -> Bool {
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        func snap(_ v: Float) -> Float { (v / step).rounded() * step }
        switch code {
        case 0, 1, 7:                                                          // volume up / down, mute
            guard SystemLevels.volumeControllable else { return false }         // e.g. HDMI output: leave it to the system
            guard down else { return true }
            let wasMuted = SystemLevels.muted() ?? false
            let cur = SystemLevels.volume() ?? 0
            if code == 7 {
                let now = !wasMuted
                if SystemLevels.setMuted(now) {
                    showHUD(.volume, cur, muted: now || cur < 0.001)
                } else {
                    if cur > 0.001 { lastAudibleVolume = cur }
                    let value: Float = cur > 0.001 ? 0 : lastAudibleVolume
                    guard SystemLevels.setVolume(value) else { return false }
                    showHUD(.volume, value, muted: value < 0.001)
                }
                return true
            }
            if wasMuted { SystemLevels.setMuted(false) }
            let nv = min(1, max(0, snap(cur) + (code == 0 ? step : -step)))
            guard SystemLevels.setVolume(nv) else { return false }
            showHUD(.volume, nv, muted: nv < 0.001)
            return true
        case 2, 3:                                                             // brightness up / down
            guard SystemLevels.brightnessControllable else { return false }
            guard down else { return true }
            let cur = brightTarget ?? SystemLevels.brightness() ?? 0     // chain presses from where the glide is heading
            let nb = min(1, max(0, snap(cur) + (code == 2 ? step : -step)))
            rampBrightness(to: nb)
            showHUD(.brightness, nb)
            return true
        default:
            return false                                                       // keyboard backlight etc.: untouched
        }
    }

    /// Eases the real brightness to `t` (~0.25s) instead of jumping a whole step at once.
    func rampBrightness(to t: Float) {
        brightTarget = t
        guard brightTimer == nil else { return }
        brightCur = SystemLevels.brightness() ?? t
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let s = self, let target = s.brightTarget else { tm.invalidate(); self?.brightTimer = nil; return }
            let d = target - s.brightCur
            if abs(d) < 0.004 {
                s.brightCur = target; SystemLevels.setBrightness(target)
                s.brightTarget = nil; tm.invalidate(); s.brightTimer = nil
                return
            }
            s.brightCur += d * 0.22                                            // ease-out
            SystemLevels.setBrightness(s.brightCur)
        }
        RunLoop.main.add(timer, forMode: .common); brightTimer = timer
    }

    /// The pointer set the level on the HUD bar.
    func hudDragged(_ v: Float) {
        let demo = demoVolume || demoBrightness                                 // demos never touch the real levels
        switch hudKind {
        case .volume:
            if !demo { if SystemLevels.muted() == true { SystemLevels.setMuted(false) }; SystemLevels.setVolume(v) }
            showHUD(.volume, v, muted: v < 0.001, seconds: 1.8)
        case .brightness:
            brightTarget = nil                                                  // cancel any glide: follow the pointer directly
            if !demo { SystemLevels.setBrightness(v) }
            showHUD(.brightness, v, seconds: 1.8)
        }
    }

    func setupKeyTap() {
        guard ProcessInfo.processInfo.environment["NI_NOKEYTAP"] == nil else { return }     // test hook
        func tryInstall() {
            if !keyTap.isActive, AXIsProcessTrusted(), keyTap.install(),
               ProcessInfo.processInfo.environment["NI_DEBUG"] != nil {
                FileHandle.standardError.write("media key tap installed\n".data(using: .utf8)!)
            }
        }
        tryInstall()
        let kt = Timer(timeInterval: 5, repeats: true) { _ in tryInstall() }   // picks up a later grant
        kt.tolerance = 2
        RunLoop.main.add(kt, forMode: .common); keyTapTimer = kt
    }

    func showBanner(_ k: BannerKind, autoHide: TimeInterval? = nil, feedback: Bool = true) {
        banner = k
        bannerHideAt = Date().addingTimeInterval(autoHide ?? 4)
        pinned = true
        if feedback { haptic(.levelChange) }
    }

    func showAlert(_ text: String, seconds: TimeInterval = 3.5) {
        if let cur = alertText, Date() < alertUntil, cur != text { alertText = cur + "  ·  " + text }   // merge simultaneous alerts
        else { alertText = text }
        alertUntil = Date().addingTimeInterval(seconds)
        pinned = true                                // alerts open it and it stays until an outside click
        haptic(.levelChange)
    }
}
