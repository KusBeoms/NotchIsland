import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Which shape the island takes, and the animation tick.

extension App {
    func desiredShape() -> Shape {
        if pinned && !liveActivity && !forceOpen { pinned = false }   // nothing left to show
        if !pinned { selected = nil; locked = false; lyricsRequested = false }     // so an ended activity also releases the lock
        if forceOpen || pinned || hudActive || dropping { return .expanded }
        if pressing || Date() < popUntil { return .pressed }
        if Date() < hoverUntil { return .peek }       // hovering only nudges it; a long press opens it
        if !acts.isEmpty { return .activity }
        return .collapsed
    }

    /// The pointer is on the real (hardware) notch.
    var overRealNotch: Bool {
        NSRect(x: notchLeft, y: screen.frame.maxY - notchH, width: notchW, height: notchH + 4).contains(NSEvent.mouseLocation)
    }

    func applyShape() {
        syncActivities()                             // the list must be current before deciding what is on screen
        let target = desiredShape()
        if target != shape {
            if target == .peek && shape != .pressed { haptic(.alignment) }   // light tick when the pointer arrives
            shape = target
            if target != .expanded && panel.isKeyWindow { releaseKeyboardFocus() }
            if target == .expanded { fileInfo.removeAll(); c.fileShown = nil }   // size / folder may have changed since it was last opened
            refreshUI()                                // wings/body change with the shape
            switch target {
            case .pressed:  stiffness = 520; damping = 42
            case .peek:     stiffness = 380; damping = 37
            case .expanded: stiffness = 300; damping = 30
            case .collapsed: stiffness = 120; damping = 22
            default:        stiffness = 300; damping = 34
            }
        }
        let onNotch = overRealNotch
        if !onNotch { swellSuppressed = false }
        let wantSwell: CGFloat = (shape == .expanded && !swellSuppressed && !hudActive && onNotch)
            ? (pressedWhileExpanded ? 0.07 : 0.04) : 0
        if wantSwell != expandedSwell {
            if shape == .expanded {
                if wantSwell > expandedSwell { stiffness = 420; damping = 30 }        // swells under the pointer
                else if locked { stiffness = 650; damping = 22 }                      // pinned: snaps back like a sticker pressed on
                else { stiffness = 380; damping = 36 }
            }
            expandedSwell = wantSwell
        }
        var wake = false
        let r = frame(for: shape)
        // While you scroll, the invisible margin under the island keeps its old extent (the card itself shrinks to fit), so the
        // pointer stays inside the window even when the next card is lower. It is let go a second after the last scroll.
        if !scrollHolding { holdH = 0 }
        let holdExtra = scrollHolding ? max(0, holdH - r.height) : 0
        if abs(dialMargin + holdExtra - mainP.m.tgt) > 0.01 { mainP.m.tgt = dialMargin + holdExtra; wake = true }
        if abs(r.minX - mainP.x.tgt) > 0.01 || abs(r.width - mainP.w.tgt) > 0.01 || abs(r.height - mainP.h.tgt) > 0.01 {
            mainP.x.tgt = r.minX; mainP.w.tgt = r.width; mainP.h.tgt = r.height
            wake = true
        }
        if wake { atRest = false; link?.isPaused = false }
    }

    @objc func animTick(_ l: CADisplayLink) {
        let dt = min(max(l.targetTimestamp - l.timestamp, 1.0 / 240), 1.0 / 30)
        let steps = Int((dt * 240).rounded(.up)); let h = dt / CGFloat(steps)
        var allSettled = true
        for p in [mainP!] where p.active || p.visible {
            let isMain = p === mainP
            let k: CGFloat = isMain ? stiffness : 300, cd: CGFloat = isMain ? damping : 28
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { p.snap() }
            for _ in 0..<steps {
                p.x.step(h, k, cd)
                p.w.step(h, k, cd)
                p.h.step(h, k, cd); p.ty.step(h, k, cd); p.m.step(h, k, cd)
            }
            if isMain {
                // Momentum from an interrupted move must never uncover the hardware notch.
                if p.x.cur > notchLeft { p.x.cur = notchLeft; if p.x.vel > 0 { p.x.vel = 0 } }
                if p.x.cur + p.w.cur < notchRight { p.w.cur = notchRight - p.x.cur; if p.w.vel < 0 { p.w.vel = 0 } }
                if p.h.cur < notchH { p.h.cur = notchH; if p.h.vel < 0 { p.h.vel = 0 } }
            }
            if p.settled { p.snap() } else { allSettled = false }
            if !p.active && p.settled && p.w.cur < 1.5 {          // shrunk away: take the window off screen
                p.panel.orderOut(nil); p.shadow?.orderOut(nil); p.visible = false; p.w.jump(0)
                continue
            }
            if !isMain { p.panel.alphaValue = p.fullW > 0 ? min(1, max(0, p.w.cur / p.fullW)) : 0 }
            let margin = max(p.m.cur, 0)
            let f = NSRect(x: p.x.cur.rounded(), y: screen.frame.maxY - p.ty.cur - p.h.cur, width: max(p.w.cur, 1), height: max(p.h.cur, 1))   // the island
            if isMain {
                let baseWidth = expandedSize().w
                let k = baseWidth > 0 ? max(1, min(1.12, p.w.cur / baseWidth)) : 1
                view.refHeight = shape == .expanded ? p.h.cur / k : 0
                view.swellInset = shape == .expanded ? max(-12, min(12, (screen.frame.midX - baseWidth / 2) - f.minX)) : 0     // pin the content to its resting spot (absolute), whatever the island does round it
            }
            if isMain { view.bottomInset = margin; if lockIsland != f { lockIsland = f; if locked { updateLockBorder() } } }
            p.panel.setFrame(NSRect(x: f.minX, y: f.minY - margin, width: f.width, height: f.height + margin), display: true)
            if let sh = p.shadow {
                sh.setFrame(f.insetBy(dx: -ShadowView.pad, dy: -ShadowView.pad), display: true)
                sh.alphaValue = p.panel.alphaValue
            }
        }
        atRest = mainP.settled
        if allSettled { l.isPaused = true }
    }
}
