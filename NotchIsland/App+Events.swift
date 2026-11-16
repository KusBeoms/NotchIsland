import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Event sources instead of polling: screens, Esc, volume, battery, music apps, output device, sleep.

extension App {
    // MARK: screen changes

    /// Display plugged / unplugged, resolution or arrangement changed: follow the notch screen and rebuild what is tied to it.
    func watchScreens() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let s = self else { return }
            let ns = App.pickScreen()
            s.screen = ns
            s.view.content.notchH = s.notchH
            s.link?.invalidate()
            s.link = ns.displayLink(target: s, selector: #selector(App.animTick(_:)))
            s.link?.add(to: .main, forMode: .common)
            s.link?.isPaused = false
            let r = s.frame(for: s.shape)
            s.mainP.x.jump(r.minX); s.mainP.w.jump(r.width); s.mainP.h.jump(r.height)
            s.mainP.x.tgt = r.minX; s.mainP.w.tgt = r.width; s.mainP.h.tgt = r.height
            s.atRest = false
            s.refreshUI()
        }
    }

    // MARK: Esc closes the open island

    func watchEscape() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let s = self, NSApp.modalWindow == nil else { return e }
            if e.keyCode == 53 && (s.pinned || s.hudActive), s.dismissIsland(clearHUD: true) {
                s.releaseKeyboardFocus(); return nil
            }
            guard s.panel.isKeyWindow, s.shape == .expanded else { return e }
            let modifiers = e.modifierFlags.intersection([.command, .control, .option])
            guard modifiers.isEmpty else { return e }
            if e.keyCode == 48 { KeyboardFocus.visible = true; s.advanceKeyboardSelection(backwards: e.modifierFlags.contains(.shift)); return nil }
            if [36, 76, 49].contains(e.keyCode), let button = s.panel.firstResponder as? NSButton {
                // Without a visible ring nothing looks focused, so Return / Space must not press the hidden first responder either.
                if KeyboardFocus.visible && !e.isARepeat && button.isEnabled { button.performClick(nil) }
                return nil
            }
            return e
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, let s = self, s.pinned else { return }      // 53 = Esc (needs the Accessibility permission, like the key tap)
            s.dismissIsland(clearHUD: true)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
            if KeyboardFocus.visible { KeyboardFocus.visible = false; NSApp.keyWindow?.contentView?.needsDisplay = true }   // the mouse takes over: no ring
            return e
        }
    }

    func accessibilityLabels() {
        let labels: [(NSButton, String)] = [(c.prevB, "이전 곡"), (c.playB, "재생 / 일시정지"), (c.nextB, "다음 곡"),
                                            (c.pauseB, "타이머 일시정지 / 계속"), (c.cancelB, "타이머 취소"),
                                            (c.fRevealB, "Finder에서 보기"), (c.fRemoveB, "주머니에서 빼기")]
        for (b, t) in labels { b.setAccessibilityLabel(t); b.toolTip = t }
        view.dial.setAccessibilityLabel("활동 전환")
        view.dial.toolTip = "드래그하거나 가로로 스크롤하여 활동 전환"
        c.hBar.setAccessibilityLabel("볼륨 / 밝기")
        c.progress.setAccessibilityLabel("재생 위치")
    }

    // MARK: event sources (instead of polling)


    private func volAddresses() -> [AudioObjectPropertyAddress] {
        [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute].map {
            AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        }
    }
    /// Volume / mute changes of the current output device arrive as events; the slow poll is only a safety net.
    func watchVolume() {
        if let b = volBlock, volDev != 0 { for var a in volAddresses() { AudioObjectRemovePropertyListenerBlock(volDev, &a, .main, b) } }
        volBlock = nil; volDev = 0
        guard let d = SystemLevels.outputDevice() else { return }
        let b: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.pollVolume() }
        for var a in volAddresses() { AudioObjectAddPropertyListenerBlock(d, &a, .main, b) }
        volDev = d; volBlock = b
    }

    /// Plugging / unplugging and level changes arrive from IOKit: the banner shows at once and nothing polls.
    func watchBattery() {
        let cb: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let app = Unmanaged<App>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { app.pollBattery(); app.tBattery = CFAbsoluteTimeGetCurrent() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(cb, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes); batteryRL = src
        }
    }

    /// Music and Spotify announce every play / pause / track change: look up what is playing right then.
    func watchMusicApps() {
        let dc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            dc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let s = self else { return }
                s.musicDebounce?.invalidate()
                let t = Timer(timeInterval: 0.35, repeats: false) { [weak s] _ in s?.pollMusic(); s?.tMusic = CFAbsoluteTimeGetCurrent() }
                RunLoop.main.add(t, forMode: .common); s.musicDebounce = t
            }
        }
    }


    /// Every real change of the default output (connect, disconnect, manual switch) starts the new output at zero volume
    /// (intended behavior, including when headphones are unplugged and the built-in speakers become the output),
    /// and refreshes the Bluetooth report. Opt out in the settings window, or: `defaults write <bundle id> zeroVolumeOnOutputChange -bool NO`.
    func watchOutputDevice() {
        lastOutDev = SystemLevels.outputDevice() ?? 0
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            guard let s = self else { return }
            // Debounce: routing churn emits bursts of notifications; act once the output has settled.
            s.outDebounce?.invalidate()
            let t = Timer(timeInterval: 0.4, repeats: false) { [weak s] _ in s?.outputDeviceSettled() }
            RunLoop.main.add(t, forMode: .common); s.outDebounce = t
        }
    }

    private func outputDeviceSettled() {
        let dev = SystemLevels.outputDevice() ?? 0
        guard dev != lastOutDev else { return }          // same device re-announced: nothing to do
        lastOutDev = dev
        hudUntil = .distantPast
        lastVol = nil; lastMute = nil
        watchVolume()                                    // listen on the new device first, then change its level
        let enabled = Settings.zeroVolumeOnOutputChange
        if enabled, !(demoVolume || demoBrightness) { SystemLevels.setVolume(0) }
        scheduleAirPodsRefresh()
    }

    /// Asleep or screen off: nothing is visible, so stop the main loop entirely until the Mac wakes.
    func watchSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.stepTimer?.invalidate(); self?.stepTimer = nil }
        }
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                guard let s = self, s.stepTimer == nil else { return }
                s.scheduleStep(busy: true)
            }
        }
    }
}
