import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Island (black body; presses outside buttons go to the app)

final class IslandView: FileDragView {
    var onPress: (() -> Void)?
    var onRelease: ((Bool) -> Void)?       // true when the finger came up inside the island
    let content = Content(frame: .zero)
    let dial = DialView()                  // drawn outside the black body, round its lower edge
    private let body = NSView()            // the black island itself (masked to the notch shape); `content` lives in it
    private let shapeMask = CAShapeLayer()
    var earLeft = true { didSet { if earLeft != oldValue { needsLayout = true } } }
    var earRight = true { didSet { if earRight != oldValue { needsLayout = true } } }   // false: the right edge is flush with the notch
    /// Room under the island (the window is taller than the island by this much) for the dial's ticks.
    var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { needsLayout = true } } }
    var bodyRect: NSRect { NSRect(x: 0, y: bottomInset, width: bounds.width, height: max(bounds.height - bottomInset, 0)) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor.black.cgColor
        body.layer?.mask = shapeMask
        content.frame = bounds
        content.autoresizingMask = []                     // laid out by hand: it sits between the ears
        body.addSubview(content)
        dial.alphaValue = 0
        addSubview(dial)                                  // behind the island: the ends of the dial tuck in behind the black body
        addSubview(body)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        body.frame = bodyRect
        let w = body.bounds.width, h = body.bounds.height
        let t = earRadius(h)
        let l = earLeft ? t : 0, r = earRight ? t : 0
        content.frame = NSRect(x: l, y: 0, width: max(0, w - l - r), height: h)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shapeMask.frame = body.bounds
        shapeMask.path = notchPath(w, h, earL: earLeft, earR: earRight)
        CATransaction.commit()
        dial.frame = bounds
        dial.geometry = DialView.Geometry(body: bodyRect)
    }

    var onOpenSource: (() -> Void)?
    private var sourceTapActive = false
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }

    // Files dragged onto the island (from Finder...) go into the shelf.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dlog("draggingEntered src=\(String(describing: sender.draggingSource)) frame=\(window?.frame ?? .zero)")
        if sender.draggingSource is FileDragView { return [] }        // our own file dragged back onto the island: ignore
        onDragEnter?(); return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { sender.draggingSource is FileDragView ? [] : .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragExit?() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dlog("performDragOperation")
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDragExit?()
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    /// Only controls that are actually visible can take a click. (Hidden-by-alpha controls stacked on top of a
    /// visible one used to swallow its clicks.) Everything else is a press on the island itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return nil }
        let here = convert(point, from: sv)
        let strip = NSRect(x: 0, y: 0, width: bounds.width, height: bottomInset + 6)      // the dial, just under the island
        guard bodyRect.contains(here) || (bottomInset > 0 && strip.contains(here)) else { return nil }
        guard bodyRect.contains(here) else { return dial.hitTest(here) ?? self }
        let p = content.convert(here, from: self)
        if !content.activityRow.isHidden, content.activityRow.frame.contains(p) {
            return content.activityRow.hitTest(p)
        }
        for v in content.subviews.reversed() where (v is NSButton || v is LevelBar || v is ProgressBar) && !v.isHidden && v.alphaValue > 0.3 {
            if v.frame.contains(p) { return v }
        }
        return self
    }

    private func overSource(_ e: NSEvent) -> Bool {
        guard content.body == .media, content.art.alphaValue > 0.3 else { return false }
        return content.sourceRect.contains(content.convert(e.locationInWindow, from: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard bodyRect.contains(convert(event.locationInWindow, from: nil)) else { return }       // the dial is for scrolling only
        downPoint = event.locationInWindow
        sourceTapActive = overSource(event)
        if !sourceTapActive { onPress?() }
    }
    override func mouseUp(with event: NSEvent) {
        if sourceTapActive {
            sourceTapActive = false
            if overSource(event) { onOpenSource?() }
            return
        }
        onRelease?(bodyRect.contains(convert(event.locationInWindow, from: nil)))
    }
}

