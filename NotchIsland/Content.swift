import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Content (flipped: y grows downward from the top of the island)

/// A view that can pick up a file and drag it out. The file under the pointer is decided by `fileForDrag`; once the drop
/// has been accepted somewhere else, `onDragFinished` is told (the file then leaves the pocket).
class FileDragView: NSView, NSDraggingSource {
    var fileForDrag: ((NSEvent) -> URL?)?
    var onDragBegan: (() -> Void)?
    var onDragFinished: ((URL, Bool) -> Void)?
    var downPoint: NSPoint?
    private var draggingURL: URL?

    override func mouseDragged(with event: NSEvent) {
        guard draggingURL == nil, let d = downPoint, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 4,
              let u = fileForDrag?(event) else { return }
        downPoint = nil; draggingURL = u
        onDragBegan?()
        let item = NSDraggingItem(pasteboardWriter: u as NSURL)
        let img = (FilePreviews.shared.cached(for: u) ?? NSWorkspace.shared.icon(forFile: u.path)).copy() as! NSImage
        img.size = NSSize(width: 48, height: 48)
        let at = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: at.x - 24, y: at.y - 24, width: 48, height: 48), contents: img)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let u = draggingURL { onDragFinished?(u, !operation.isEmpty) }
        draggingURL = nil
    }
}

enum Body { case none, hud, banner, alert, media, timer, file, drop }
enum LevelKind { case volume, brightness }

/// Everything that can be a live activity, in the order they are listed when several run at once.
enum ActKind: Hashable { case media, timer, charging, lowBattery, airpods, file(URL) }     // every file in the pocket is an activity
let allKinds: [ActKind] = [.media, .timer, .charging, .airpods, .lowBattery]

/// The two small views an activity can be drawn with: a 24pt icon, and a detail (time, %, equalizer, ring).
final class SlotItem {
    let icon: NSView
    let detail: NSView
    let detailSize: CGSize
    init(icon: NSView, detail: NSView, detailSize: CGSize) { self.icon = icon; self.detail = detail; self.detailSize = detailSize }
    var pillWidth: CGFloat { 24 + 6 + detailSize.width }
}

/// One critically-damped-ish spring channel.
struct SpringV {
    var cur: CGFloat = 0, vel: CGFloat = 0, tgt: CGFloat = 0
    mutating func step(_ h: CGFloat, _ k: CGFloat, _ c: CGFloat) { vel += (-k * (cur - tgt) - c * vel) * h; cur += vel * h }
    var settled: Bool { abs(cur - tgt) < 0.1 && abs(vel) < 2 }
    mutating func snap() { cur = tgt; vel = 0 }
    mutating func jump(_ v: CGFloat) { cur = v; tgt = v; vel = 0 }
}

/// A soft shadow behind an island: a bigger, click-through window that draws the island's own shape with a blurred shadow.
/// (The system window shadow draws a light hairline around the shape, which does not suit something that merges with the notch.)
final class ShadowView: NSView {
    static let pad: CGFloat = 36                                  // room around the island for the blur
    var pathProvider: ((CGSize) -> CGPath)?
    private let shape = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = NSColor.black.cgColor
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0.4
        shape.shadowRadius = 12
        shape.shadowOffset = CGSize(width: 0, height: -5)       // falls a little downwards
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let pad = ShadowView.pad
        let size = CGSize(width: max(bounds.width - 2 * pad, 1), height: max(bounds.height - 2 * pad, 1))
        let path = pathProvider?(size) ?? CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var move = CGAffineTransform(translationX: pad, y: pad)
        let placed = path.copy(using: &move) ?? path
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = placed
        shape.shadowPath = placed
        CATransaction.commit()
    }
}

/// A window (the island itself, the detached icon, the pill under the notch) and the springs that move it.
final class Piece {
    let panel: NSPanel
    var shadow: NSPanel?
    var x = SpringV(), w = SpringV(), h = SpringV(), ty = SpringV()    // left edge, width, height, distance from the top of the screen
    var m = SpringV()                                                  // extra room under the island (for the dial)
    var fullW: CGFloat = 1
    var active = false      // wants to be on screen
    var visible = false     // is on screen (an inactive piece stays until it has shrunk away)
    init(panel: NSPanel) { self.panel = panel }
    var settled: Bool { x.settled && w.settled && h.settled && ty.settled && m.settled }
    func snap() { x.snap(); w.snap(); h.snap(); ty.snap(); m.snap() }
}

/// A second activity row embedded in the notch body.
final class ActivityRowView: FileDragView {
    var onPress: (() -> Void)?
    var onRelease: ((Bool) -> Void)?
    var items: [SlotItem] = [] { didSet { needsLayout = true } }
    private(set) var itemFrames: [NSRect] = []
    var withDetail = false { didSet { needsLayout = true } }
    private let shapeMask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = shapeMask
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let r = bounds.height / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shapeMask.frame = bounds
        shapeMask.path = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()
        let widths = items.map { withDetail ? $0.pillWidth : 24 }
        let total = widths.reduce(0, +) + 16 * CGFloat(max(items.count - 1, 0))
        var x = (bounds.width - total) / 2
        itemFrames = []
        for (it, wd) in zip(items, widths) {
            itemFrames.append(NSRect(x: x - 8, y: 0, width: wd + 16, height: bounds.height))
            it.icon.frame = NSRect(x: x, y: (bounds.height - 24) / 2, width: 24, height: 24)
            if withDetail {
                it.detail.frame = NSRect(x: x + 30, y: (bounds.height - it.detailSize.height) / 2,
                                         width: it.detailSize.width, height: it.detailSize.height)
            }
            x += wd + 16
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return nil }
        return bounds.contains(convert(point, from: sv)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow; onPress?() }
    override func mouseUp(with event: NSEvent) { onRelease?(bounds.contains(convert(event.locationInWindow, from: nil))) }
}

final class Content: Flip {
    let activityRow = ActivityRowView(frame: .zero)
    var notchH: CGFloat = 32
    var bandH: CGFloat = 32          // height of the top band the wings live in (taller while compact)
    var body: Body = .none
    var ending = false               // everything is going away: fade slowly
    var leftView: NSView?            // slot views drawn beside the notch (managed by App)
    var rightView: NSView?
    var rightSize = CGSize(width: 24, height: 24)
    var bannerSymbol = ""
    var fileShown: URL?
    var leftSize = CGSize(width: 24, height: 24)
    private var lastAlpha: [ObjectIdentifier: CGFloat] = [:]

    private var transitionKey = ""

    func transition(to key: String) {
        guard transitionKey != key else { return }
        let hadContent = !transitionKey.isEmpty
        transitionKey = key
        guard hadContent, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for v in [art, titleL, artistL, fIcon, fName, fSub, tTime, tLabel] where v.alphaValue > 0.3 {
            v.wantsLayer = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.25; fade.toValue = 1; fade.duration = 0.22
            v.layer?.add(fade, forKey: "activityChange")
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = 5; slide.toValue = 0; slide.duration = 0.24
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            v.layer?.add(slide, forKey: "activitySlide")
        }
    }

    // media body
    let art = ArtView(radius: 10)
    let titleL = makeLabel(15, .semibold, .white)
    let artistL = makeLabel(14, .regular, NSColor(white: 1, alpha: 0.55))
    let bodyEq = EqView()
    let progress = ProgressBar()
    let elapsedL = makeLabel(11, .medium, NSColor(white: 1, alpha: 0.5), mono: true)
    let remainL = makeLabel(11, .medium, NSColor(white: 1, alpha: 0.5), mono: true, align: .right)
    let prevB = makeSymbolButton("backward.fill", 24, .white)
    let playB = makeSymbolButton("pause.fill", 30, .white)
    let nextB = makeSymbolButton("forward.fill", 24, .white)
    // timer body
    let pauseB = makeSymbolButton("pause.fill", 20, accent)
    let cancelB = makeSymbolButton("xmark", 18, .white)
    let tLabel = makeLabel(13, .semibold, accent, align: .right)
    let tTime = makeLabel(30, .semibold, accent, mono: true, align: .right)
    // banner body (charging / AirPods): a pill as tall as the notch, content on both sides of it
    var bannerIsAir = false
    let bTitle = makeLabel(16, .semibold, .white)
    let bPct = makeLabel(16, .semibold, bannerGreen, mono: true, align: .right)
    let bGlyph = BatteryGlyph()
    let bAir = NSImageView()
    let bRing = RingView()
    let aTitle = makeLabel(14, .semibold, .white)
    let aState = makeLabel(12, .medium, .white)
    let aBattery = makeLabel(11, .medium, NSColor(white: 1, alpha: 0.6), align: .right)
    // volume / brightness HUD: icon on the left of the notch, level bar on the right
    let hIcon = NSImageView()
    let hBar = LevelBar()
    var hIconName = ""
    // alert body
    let alertL = makeLabel(15, .semibold, .white, align: .center)
    // file body: the file's icon, name and where it lives; buttons to show it in Finder / let it go
    let fIcon = FilePreviewView()
    let fName = makeLabel(15, .semibold, .white)
    let fSub = makeLabel(12, .regular, NSColor(white: 1, alpha: 0.55))
    let fRevealB = makeSymbolButton("magnifyingglass", 15, .white)
    let fRemoveB = makeSymbolButton("xmark", 14, .white)
    // drop body: shown while a file is being dragged towards the notch
    let dropIcon = NSImageView()
    let dropHint = makeLabel(14, .medium, NSColor(white: 1, alpha: 0.75))

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in [pauseB, cancelB] { b.wantsLayer = true; b.layer?.cornerRadius = 22 }
        pauseB.layer?.backgroundColor = accent.withAlphaComponent(0.28).cgColor
        cancelB.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        hIcon.contentTintColor = .white
        dropIcon.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 26, weight: .semibold))
        dropIcon.contentTintColor = NSColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1)
        dropHint.stringValue = "여기에 놓으세요"
        activityRow.withDetail = true
        activityRow.isHidden = true
        addSubview(activityRow)
        fIcon.imageScaling = .scaleProportionallyUpOrDown
        for v in all { addSubview(v); v.alphaValue = 0 }
    }
    required init?(coder: NSCoder) { fatalError() }

    var all: [NSView] {
        [art, titleL, artistL, bodyEq, progress, elapsedL, remainL,
         prevB, playB, nextB, pauseB, cancelB, tLabel, tTime, alertL, bTitle, bPct, bGlyph, bAir, bRing, aTitle, aState, aBattery, hIcon, hBar]
            + [fIcon, fName, fSub, fRevealB, fRemoveB, dropIcon, dropHint]
    }

    /// Cover + title + artist: tapping it opens the app that is playing.
    var sourceRect: NSRect { art.frame.union(titleL.frame).union(artistL.frame) }

    override func layout() {
        super.layout()
        let w = bounds.width, pad: CGFloat = 16, top = notchH + 2
        // wings: the icon tile gets the same margin on the left, top and bottom
        let tile: CGFloat = 24
        let m = max((bandH - tile) / 2, 0)
        let leftInset: CGFloat = bandH > notchH ? m : 14        // compact pill: even margins; expanded: wing icons
        let rightInset: CGFloat = bandH > notchH ? (rightSize.width > tile ? m + 6 : m) : 14
        leftView?.frame = NSRect(x: leftInset, y: (bandH - leftSize.height) / 2, width: leftSize.width, height: leftSize.height)
        rightView?.frame = NSRect(x: w - rightInset - rightSize.width, y: (bandH - rightSize.height) / 2,
                                  width: rightSize.width, height: rightSize.height)
        activityRow.frame = NSRect(x: 8, y: bandH + 1, width: max(0, w - 16), height: 34)
        // media
        art.frame = NSRect(x: pad, y: top, width: 48, height: 48)
        let tx = pad + 48 + 12, tw = max(0, w - tx - pad - 26)
        titleL.frame = NSRect(x: tx, y: top + 4, width: tw, height: 20)
        artistL.frame = NSRect(x: tx, y: top + 25, width: tw, height: 18)
        bodyEq.frame = NSRect(x: w - pad - 20, y: top + 6, width: 20, height: 20)
        progress.frame = NSRect(x: pad, y: top + 50, width: w - 2 * pad, height: 22)      // a taller hit area around the 4pt line
        elapsedL.frame = NSRect(x: pad, y: top + 62, width: 60, height: 14)
        remainL.frame = NSRect(x: w - pad - 60, y: top + 62, width: 60, height: 14)
        let cy = top + 76
        playB.frame = NSRect(x: w / 2 - 25, y: cy, width: 50, height: 40)
        prevB.frame = NSRect(x: w / 2 - 25 - 70, y: cy, width: 50, height: 40)
        nextB.frame = NSRect(x: w / 2 - 25 + 70, y: cy, width: 50, height: 40)
        // timer
        pauseB.frame = NSRect(x: pad, y: top + 2, width: 44, height: 44)
        cancelB.frame = NSRect(x: pad + 52, y: top + 2, width: 44, height: 44)
        tLabel.frame = NSRect(x: w - pad - 150, y: top - 2, width: 150, height: 16)
        tTime.frame = NSRect(x: w - pad - 158, y: top + 10, width: 158, height: 42)
        // banner (left/right inset 14 inside the body)
        bTitle.frame = NSRect(x: 14, y: (notchH - 20) / 2, width: 100, height: 20)
        bAir.frame = NSRect(x: 6, y: (notchH - 26) / 2, width: 28, height: 26)
        bGlyph.frame = NSRect(x: w - 14 - 34, y: (notchH - 15) / 2, width: 34, height: 15)
        bPct.frame = NSRect(x: w - 14 - 34 - 8 - 56, y: (notchH - 20) / 2, width: 56, height: 20)
        bRing.frame = NSRect(x: w - 6 - 26, y: (notchH - 26) / 2, width: 26, height: 26)
        if bannerIsAir {
            bAir.frame = NSRect(x: pad, y: top + 9, width: 32, height: 32)
            aTitle.frame = NSRect(x: pad + 44, y: top + 7, width: max(0, w - pad * 2 - 102), height: 18)
            aState.frame = NSRect(x: pad + 44, y: top + 29, width: max(0, w - pad * 2 - 102), height: 16)
            bRing.frame = NSRect(x: w - pad - 28, y: top + 5, width: 28, height: 28)
            aBattery.frame = NSRect(x: w - pad - 70, y: top + 36, width: 70, height: 16)
        }
        // HUD
        hIcon.frame = NSRect(x: pad, y: top + 6, width: 24, height: 24)          // below the notch, icon on the left
        hBar.frame = NSRect(x: pad + 24 + 14, y: top + 7, width: max(0, w - pad - 24 - 14 - pad), height: 22)
        // alert
        alertL.frame = NSRect(x: pad, y: notchH + 6, width: w - 2 * pad, height: 22)
        // file
        fIcon.frame = NSRect(x: pad, y: top, width: 48, height: 48)
        let fx = pad + 48 + 12, fw = max(0, w - fx - pad)
        fName.frame = NSRect(x: fx, y: top + 4, width: fw, height: 20)
        fSub.frame = NSRect(x: fx, y: top + 25, width: fw, height: 16)
        fRevealB.frame = NSRect(x: w - pad - 88, y: top + 52, width: 40, height: 40)
        fRemoveB.frame = NSRect(x: w - pad - 40, y: top + 52, width: 40, height: 40)
        // drop hint
        dropIcon.frame = NSRect(x: pad, y: top + 6, width: 36, height: 36)
        dropHint.frame = NSRect(x: pad + 46, y: top + 14, width: max(0, w - pad * 2 - 46), height: 20)
    }

    /// Cross-fade every element to what the current shape/body/wings need.
    func applyVisibility(expanded: Bool) {
        let b = body
        let want: [(NSView, Bool)] = [
            (art, expanded && b == .media), (titleL, expanded && b == .media), (artistL, expanded && b == .media),
            (bodyEq, expanded && b == .media), (progress, expanded && b == .media),
            (elapsedL, expanded && b == .media), (remainL, expanded && b == .media),
            (prevB, expanded && b == .media), (playB, expanded && b == .media), (nextB, expanded && b == .media),
            (pauseB, expanded && b == .timer), (cancelB, expanded && b == .timer),
            (tLabel, expanded && b == .timer), (tTime, expanded && b == .timer),
            (alertL, expanded && b == .alert),
            (bTitle, expanded && b == .banner && !bannerIsAir), (bPct, expanded && b == .banner && !bannerIsAir),
            (bGlyph, expanded && b == .banner && !bannerIsAir),
            (bAir, expanded && b == .banner && bannerIsAir), (bRing, expanded && b == .banner && bannerIsAir),
            (aTitle, expanded && b == .banner && bannerIsAir),
            (aState, expanded && b == .banner && bannerIsAir),
            (aBattery, expanded && b == .banner && bannerIsAir),
            (hIcon, expanded && b == .hud), (hBar, expanded && b == .hud),
            (fIcon, expanded && b == .file), (fName, expanded && b == .file), (fSub, expanded && b == .file),
            (fRevealB, expanded && b == .file), (fRemoveB, expanded && b == .file),
            (dropIcon, expanded && b == .drop), (dropHint, expanded && b == .drop),
        ]
        for (v, on) in want {
            let a: CGFloat = on ? 1 : 0
            let key = ObjectIdentifier(v)
            if lastAlpha[key] == a { continue }
            lastAlpha[key] = a
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (on ? 0.22 : (ending ? 0.3 : 0.16))
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                v.animator().alphaValue = a
            }
        }
    }
}

