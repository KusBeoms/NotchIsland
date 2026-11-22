import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - The island's panel and the lock border.

extension App {
    func makePanel(_ frame: NSRect) -> NSPanel {
        let p = IslandPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Windows above the dragging level (500) cannot be drop targets, so stay just below it: still above menus and the Dock.
        p.level = NSWindow.Level(rawValue: 400)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false                                  // the system shadow draws a light rim; ShadowView draws a soft one instead
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return p
    }

    /// Pinned: a click-through outline along the top edge of the screen that detours round the island (never across its top).
    /// Its window is only as tall as the island, and it is taken off screen again once the fade-out has finished.
    func updateLockBorder() {
        if lockBorder == nil {
            if !lockShown { return }
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: 399)
            p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            let v = NSView(); v.wantsLayer = true
            let l = CAShapeLayer(); l.fillColor = nil; l.lineWidth = 4; l.lineCap = .round
            v.layer?.addSublayer(l)
            p.contentView = v; p.alphaValue = 0
            lockBorder = p; lockBorderLayer = l
        }
        guard let p = lockBorder, let l = lockBorderLayer else { return }
        if !lockShown && !p.isVisible { return }
        if lockShown {
            let f = screen.frame
            let stripH = min(f.height, max(1, f.maxY - lockIsland.minY + 4))
            let strip = NSRect(x: f.minX, y: f.maxY - stripH, width: f.width, height: stripH)
            let geometry = LockBorderGeometry(strip: strip, island: lockIsland, earLeft: view.earLeft, earRight: view.earRight)
            if geometry != lockBorderGeometry {                            // the path only changes when the island or its ears do
                lockBorderGeometry = geometry
                if p.frame != strip { p.setFrame(strip, display: false) }
                let W = strip.width, H = strip.height
                let R = lockIsland.offsetBy(dx: -strip.minX, dy: -strip.minY)   // the island in this window's coordinates
                let path = CGMutablePath()                                 // screen top edge, detouring round the island (y is up)
                path.move(to: CGPoint(x: 0, y: H)); path.addLine(to: CGPoint(x: R.minX, y: H))
                path.move(to: CGPoint(x: R.maxX, y: H)); path.addLine(to: CGPoint(x: W, y: H))
                path.addPath(notchPath(R.width, R.height, earL: view.earLeft, earR: view.earRight, openTop: true),
                             transform: CGAffineTransform(translationX: R.minX, y: R.minY))
                CATransaction.begin(); CATransaction.setDisableActions(true)
                l.frame = CGRect(origin: .zero, size: strip.size); l.path = path
                CATransaction.commit()
            }
            let color = (body == .media ? artColor : accent).cgColor
            if l.strokeColor == nil { l.strokeColor = color }
            else if l.strokeColor != color {                                    // a new track / card: blend into the new colour
                let a = CABasicAnimation(keyPath: "strokeColor")
                a.fromValue = l.presentation()?.strokeColor ?? l.strokeColor; a.toValue = color
                a.duration = 0.5; a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                l.strokeColor = color
                l.add(a, forKey: "strokeColor")
            }
            if !p.isVisible { p.orderFrontRegardless(); makeSticky(p) }      // sticky: stays put while Spaces slide, like the island
        }
        let target: CGFloat = lockShown ? 1 : 0
        if p.alphaValue != target && lockBorderTarget != target {
            lockBorderTarget = target
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = target }, completionHandler: { [weak self] in
                guard let self, !self.lockShown, p.alphaValue == 0 else { return }
                p.orderOut(nil); self.lockBorderGeometry = nil               // nothing invisible stays in the window list
            })
        }
        lockBorderTarget = target
    }

    /// A click-through window with a soft shadow of `provider`'s shape, kept just behind `piece`.
    func attachShadow(to piece: Piece, _ provider: @escaping (CGSize) -> CGPath) {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: 399)                  // just under the island windows
        p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
        p.ignoresMouseEvents = true                              // never in the way of a click or a drop
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let v = ShadowView(frame: .zero)
        v.pathProvider = provider
        p.contentView = v
        piece.shadow = p
    }
}
