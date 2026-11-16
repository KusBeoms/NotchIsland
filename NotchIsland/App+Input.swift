import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Pointer and light-sensor presses on the island.

extension App {
    /// Which activity is under the pointer. Anything on the notch itself or to the left of it is the activity attached
    /// to the notch on the left (the first one); the right wing, the detached icon and the pill pick their own.
    func kindAtMouse() -> ActKind? {
        let a = acts
        guard !a.isEmpty else { return nil }
        let m = NSEvent.mouseLocation
        if !rowView.isHidden, a.count >= 3 {
            let point = rowView.convert(panel.convertPoint(fromScreen: m), from: nil)
            if rowView.bounds.contains(point) {
                let items = Array(a.dropFirst(2))
                if let index = rowView.itemFrames.firstIndex(where: { $0.contains(point) }), items.indices.contains(index) { return items[index] }
                return nil
            }
        }
        if shape == .expanded {
            let point = c.convert(panel.convertPoint(fromScreen: m), from: nil)
            if let left = lastPlan?.left, c.leftView?.frame.contains(point) == true { return left }
            if let right = lastPlan?.right, c.rightView?.frame.contains(point) == true { return right }
            return nil
        }
        if a.count >= 2, m.x > notchRight { return a[1] }
        return a[0]
    }

    /// Finger down: react at once (swell; the trackpad's own click is the only haptic). With something running, a quick tap opens it on release,
    /// and holding opens it after 0.25s without waiting for the release. With nothing running it pops out and back.
    func pressBegan() {
        pressKind = kindAtMouse()
        pressedWhileExpanded = (shape == .expanded)
        lyricsHoldFired = false
        if pressedWhileExpanded {                    // already open: the release (a tap) closes it ...
            if cardKind == .media && supportsLyrics && body == .media && !overRealNotch {    // ... but holding a music card toggles the lyrics
                longPressTimer?.invalidate()
                let t = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
                    guard let s = self, s.pressedWhileExpanded, s.shape == .expanded, s.body == .media, s.supportsLyrics else { return }
                    guard s.frame(for: s.shape).insetBy(dx: -40, dy: -40).contains(NSEvent.mouseLocation) else { return }   // dragged away
                    s.lyricsHoldFired = true
                    haptic(.levelChange)
                    s.lyricsTapped()
                }
                RunLoop.main.add(t, forMode: .common)
                longPressTimer = t
            }
            return
        }
        if !liveActivity {                           // nothing to show: pop out a little and go straight back in
            popUntil = Date().addingTimeInterval(0.22)
            return
        }
        pressing = true
        longPressTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let s = self, s.pressing else { return }
            let zone = s.frame(for: s.shape)
            guard zone.insetBy(dx: -40, dy: -40).contains(NSEvent.mouseLocation) else { return }   // dragged away while holding: do nothing
            s.pressing = false
            s.selected = s.pressKind
            s.pinned = true                          // popped out: stays out until you click elsewhere
        }
        RunLoop.main.add(t, forMode: .common)
        longPressTimer = t
    }

    func pressEnded(inside: Bool) {
        longPressTimer?.invalidate(); longPressTimer = nil
        let wasPressing = pressing
        pressing = false
        if wasPressing && inside && liveActivity {   // a quick tap (trackpad click / tap-to-click) opens it
            selected = pressKind
            pinned = true
        }
        let heldForLyrics = lyricsHoldFired
        lyricsHoldFired = false
        if pressedWhileExpanded && inside && !heldForLyrics && !view.pressOnLyrics {   // a tap on the lyrics themselves does nothing
            if let kind = pressKind, kind != cardKind {
                selected = kind; pinned = true; refreshUI(); return
            }
            if hudActive { hudUntil = .distantPast }
            else if overRealNotch && pinned { locked.toggle(); swellSuppressed = locked; haptic(.levelChange) }   // tap the real notch again: lock / unlock (only a pinned island can lock)
            else { dismissIsland() }
        }
        pressedWhileExpanded = false
    }

    // MARK: sensor touch (covering the ambient light sensor)

    /// Where the island is when the sensor is covered: the gestures can be set per context (see SensorGestureMap).
    var sensorContext: SensorContext {
        guard shape == .expanded || pinned else { return .closed }
        return shape == .expanded && cardKind == .media && body == .media && supportsLyrics ? .openMusic : .openOther
    }

    /// Covered. What happens is up to the user's gesture map; the defaults are the original behaviour:
    /// open island -> shrinks back (on a music card a short cover closes it, a long one toggles the lyrics);
    /// closed and something running -> reacts at once, and keeping it covered 0.3s pops it open and keeps it;
    /// closed and nothing running -> pops out and straight back in.
    func sensorTouchBegan() {
        haptic(.alignment)
        let context = sensorContext
        if context == .closed {
            if !liveActivity { popUntil = Date().addingTimeInterval(0.22) } else { pressing = true }
        }
        longPressTimer?.invalidate(); longPressTimer = nil
        runSensor(sensorRecognizer.down(at: hardwareSeconds(), context: context, map: SensorGestureMap(Settings.sensorGestureMap)))
    }

    /// Uncovered: a short cover is a tap (or the first half of a double tap).
    func sensorTouchEnded() {
        pressing = false
        runSensor(sensorRecognizer.up(at: hardwareSeconds()))
    }

    /// Every loop pass: a hold fires once the sensor has stayed covered long enough, a lone tap once no second one can follow.
    func sensorTick() {
        guard !sensorRecognizer.isIdle else { return }
        runSensor(sensorRecognizer.tick(at: hardwareSeconds()))
    }

    func runSensor(_ events: [SensorGestureRecognizer.Event]) {
        for e in events { performSensor(e.action) }
    }

    func performSensor(_ action: SensorAction) {
        switch action {
        case .none: return
        case .openIsland:
            guard !acts.isEmpty else { return }
            pressing = false
            selected = acts.first                    // touching the sensor picks the activity attached to the notch (left)
            pinned = true
            haptic(.levelChange)
        case .closeIsland: sensorDismiss()
        case .lyrics:
            guard supportsLyrics else { return }
            haptic(.levelChange); lyricsTapped()
        case .playPause: if media != nil { haptic(.levelChange); playPauseTapped() }
        case .nextTrack: if media != nil { haptic(.levelChange); nextTapped() }
        case .previousTrack: if media != nil { haptic(.levelChange); prevTapped() }
        case .toggleTimer:
            haptic(.levelChange)
            if timer.started { timer.toggle() } else { timer.startStopwatch() }
            refreshUI()
        case .startPomodoro:
            haptic(.levelChange)
            if timer.pomodoro != nil { timer.toggle() } else { timer.startPomodoro(Settings.pomodoro) }
            refreshUI()
        }
    }

    func sensorDismiss() {
        if hudActive { guard dismissIsland(clearHUD: true, keepPinned: true) else { return } }
        else { guard dismissIsland() else { return } }
        haptic(.levelChange)
    }

    /// Toggles the lyrics over the media card itself; the island keeps its size.
    @objc func lyricsTapped() {
        guard supportsLyrics else { return }
        lyricsRequested.toggle()
        if lyricsRequested {
            selected = .media; pinned = true
            lyrics.select(lyricsTrack)
            lyrics.requestNow()                      // asked for explicitly: no waiting for a back-off
            lyrics.refreshIfNeeded()
        }
        refreshUI(); applyShape()
    }
}
