import AppKit
import CoreGraphics

// The App side of MirrorPolicy.swift: keeping the island's windows off screen while the built-in display is mirrored or the
// session is locked (the island lives in a private top-most space, level INT_MAX, which is also above a lock screen: a song or
// meeting title must not be readable there), and bringing them back afterwards.

/// Reconfiguration callback: a plain function (it can be registered and removed again with the same pointer).
private let displayReconfigured: CGDisplayReconfigurationCallBack = { _, flags, user in
    guard !flags.contains(.beginConfigurationFlag), let user else { return }          // act when the change is complete
    let app = Unmanaged<App>.fromOpaque(user).takeUnretainedValue()
    DispatchQueue.main.async { app.applyMirroring() }
}

extension App {
    /// The screen the island follows changed (or may have): recompute it and put the island where it belongs, without animation.
    func followScreen() {
        let ns = App.pickScreen()
        screen = ns
        view.content.notchH = notchH
        link?.invalidate()
        link = ns.displayLink(target: self, selector: #selector(App.animTick(_:)))
        link?.add(to: .main, forMode: .common)
        link?.isPaused = false
        let r = frame(for: shape)
        mainP.x.jump(r.minX); mainP.w.jump(r.width); mainP.h.jump(r.height)
        mainP.x.tgt = r.minX; mainP.w.tgt = r.width; mainP.h.tgt = r.height
        atRest = false
    }

    /// Called when the screens change (and once at launch): decides from the display list whether the island is hidden for
    /// mirroring. A list that cannot be read keeps the current state (no flicker on a failed query).
    func applyMirroring() {
        mirrorHidden = MirrorPolicy.nextHidden(previous: mirrorHidden, displays: mirrorInfo(), enabled: Settings.hideWhenMirroring)
        syncIslandVisibility()
    }

    /// The real lock state, asked from the session itself: the lock notifications are only a hint (any process can post one).
    static func sessionScreenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func applyLockState() {
        let locked = lockProbe()
        guard locked != screenLocked else { return }
        screenLocked = locked
        syncIslandVisibility()
    }

    /// Hides or restores the windows when `islandSuppressed` changed. Timer, media and every other state keep running underneath.
    func syncIslandVisibility() {
        let hide = islandSuppressed
        guard hide != windowsHidden else { return }
        windowsHidden = hide
        cancelPress(); dragActive = false; dragEntered = false; dragNear = false     // nothing of an interrupted pointer state may linger
        if hide {
            releaseKeyboardFocus()
            hudUntil = .distantPast
            hoverEnteredAt = nil; hoverLeftAt = nil
            panel.orderOut(nil); mainP.shadow?.orderOut(nil)
            lockBorder?.orderOut(nil); lockBorderGeometry = nil
        } else {
            followScreen()                                   // the CG callback can come before the screen-change notice
            restampDeferredAlerts()                          // a waiting alert starts its wait now, not while nobody could see it
            panel.orderFrontRegardless(); makeSticky(panel)
            if let shadow = mainP.shadow { shadow.orderFrontRegardless(); makeSticky(shadow) }
        }
        updateLockBorder()                                   // `lockShown` follows the suppression
        refreshUI(); applyShape()
    }

    func restampDeferredAlerts() {
        let now = Date()
        deferredAlerts = deferredAlerts.map { (now, $0.run) }
    }

    /// The system reports every display reconfiguration, including mirroring on / off, also when no screen-parameters notice follows.
    func watchMirroring() {
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        mirrorCallbackRegistered = true
        applyMirroring()
        applyLockState()                                     // the app may be started while the screen is locked
    }

    func unwatchMirroring() {
        guard mirrorCallbackRegistered else { return }
        mirrorCallbackRegistered = false
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }
}
