import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Small views

class Flip: NSView { override var isFlipped: Bool { true } }

/// Rounded album-art tile; shows a music-note placeholder until an image arrives.
final class ArtView: NSView {
    private let note = NSImageView()
    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        note.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        note.contentTintColor = NSColor(white: 1, alpha: 0.55)
        addSubview(note)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); note.frame = bounds }
    private weak var shown: NSImage?
    func setImage(_ img: NSImage?) {
        guard img !== shown else { return }                  // called every refresh: only react when the picture changes
        let first = shown == nil && layer?.contents == nil
        shown = img
        if !first && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { // cross-fade to the new cover instead of cutting
            let t = CATransition(); t.type = .fade; t.duration = 0.4
            t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(t, forKey: "cover")
        }
        layer?.contents = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        note.isHidden = img != nil
    }
}

final class EqView: NSView {
    private var bars: [CALayer] = []
    private var animating = false, fake = false
    private var timer: Timer?, quietSince: CFAbsoluteTime?
    private var levels: [CGFloat] = [CGFloat](repeating: 0.3, count: 5)
    var color: NSColor = accent { didSet { bars.forEach { $0.backgroundColor = color.cgColor } } }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<5 {
            let l = CALayer()
            l.backgroundColor = color.cgColor
            l.cornerRadius = 1
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
            l.transform = CATransform3DMakeScale(1, 0.3, 1)
            layer?.addSublayer(l)
            bars.append(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let bw: CGFloat = 2.5, gap = (bounds.width - bw * 5) / 4
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in bars.enumerated() {
            l.bounds = CGRect(x: 0, y: 0, width: bw, height: bounds.height)
            l.position = CGPoint(x: bw / 2 + CGFloat(i) * (bw + gap), y: 0)
        }
        CATransaction.commit()
    }
    deinit { if animating { AudioLevels.shared.release() }; timer?.invalidate() }

    func setPlaying(_ p: Bool) {
        if p == animating { return }
        dlog("EQ \(ObjectIdentifier(self).hashValue % 9973) setPlaying(\(p))")
        animating = p
        if p {
            AudioLevels.shared.retain()
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.01
            RunLoop.main.add(t, forMode: .common); timer = t
        } else {
            AudioLevels.shared.release()
            timer?.invalidate(); timer = nil
            setFake(false)
            glide(to: [CGFloat](repeating: 0.3, count: 5), rate: 0.25)
        }
    }

    private func tick() {
        guard animating else { return }
        let a = AudioLevels.shared
        if a.fresh {
            setFake(false)
            glide(to: a.bands.map { 0.18 + 0.82 * CGFloat($0) }, rate: 0.55)
            quietSince = nil
        } else {
            let now = CFAbsoluteTimeGetCurrent()
            if quietSince == nil { quietSince = now }
            if a.failed, now - quietSince! > 1.0 { setFake(true) }
            else if !a.failed { glide(to: [CGFloat](repeating: 0.18, count: 5), rate: 0.3) }     // restarting the tap: rest, never a canned loop       // still no audio tap after a while (permission missing / unsupported): canned bounce
        }
    }

    /// Eases the bars to `target`; fast on the way up and slower on the way down, like a real meter.
    private func glide(to target: [CGFloat], rate: CGFloat) {
        guard target.count >= bars.count, levels.count >= bars.count else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in 0..<5 {
            let up = target[i] > levels[i]
            levels[i] += (target[i] - levels[i]) * (up ? rate : rate * 0.45)
            bars[i].transform = CATransform3DMakeScale(1, max(0.12, min(1, levels[i])), 1)
        }
        CATransaction.commit()
    }

    private func setFake(_ on: Bool) {
        guard on != fake else { return }
        fake = on
        dlog("EQ \(ObjectIdentifier(self).hashValue % 9973) setFake(\(on))")
        for (i, l) in bars.enumerated() {
            l.removeAllAnimations()
            guard on else { continue }
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = 0.3; a.toValue = 1.0
            a.duration = 0.42 + Double(i) * 0.11
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.timeOffset = Double(i) * 0.13
            l.add(a, forKey: "eq")
        }
    }
}

final class ProgressBar: NSView {
    private let track = CALayer(), fill = CALayer()
    private static let lineH: CGFloat = 4
    /// Called while the pointer scrubs (final == false) and when it lets go (final == true), with the position 0...1.
    var onScrub: ((CGFloat, Bool) -> Void)?
    var fraction: CGFloat = 0 {
        didSet {
            guard fraction != oldValue else { return }
            let from = fill.presentation()?.frame ?? fill.frame
            relayout()
            let a = CABasicAnimation(keyPath: "bounds.size.width")
            a.fromValue = from.width; a.toValue = fill.bounds.width
            a.duration = 0.15; a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.add(a, forKey: "progress")
        }
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        track.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        track.cornerRadius = ProgressBar.lineH / 2
        fill.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
        fill.cornerRadius = ProgressBar.lineH / 2
        layer?.addSublayer(track); layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); relayout() }
    private func relayout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let y = (bounds.height - ProgressBar.lineH) / 2
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: ProgressBar.lineH)
        fill.frame = CGRect(x: 0, y: y, width: bounds.width * min(max(fraction, 0), 1), height: ProgressBar.lineH)
        CATransaction.commit()
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { Double(fraction) }
    override func accessibilityMinValue() -> Any? { 0.0 }
    override func accessibilityMaxValue() -> Any? { 1.0 }
    override func accessibilityPerformIncrement() -> Bool { adjust(0.05); return true }
    override func accessibilityPerformDecrement() -> Bool { adjust(-0.05); return true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { adjust(-0.05) }
        else if event.keyCode == 124 { adjust(0.05) }
        else { super.keyDown(with: event) }
    }
    private func adjust(_ delta: CGFloat) {
        fraction = min(1, max(0, fraction + delta)); onScrub?(fraction, true)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func scrub(_ e: NSEvent, final: Bool) {
        let f = min(max(convert(e.locationInWindow, from: nil).x / max(bounds.width, 1), 0), 1)
        fraction = f
        onScrub?(f, final)
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); scrub(event, final: false) }
    override func mouseDragged(with event: NSEvent) { scrub(event, final: false) }
    override func mouseUp(with event: NSEvent) { scrub(event, final: true) }
}

/// Pill-shaped battery with a coloured fill (like the iPhone charging banner).
final class BatteryGlyph: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var color: NSColor = bannerGreen { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let tipW: CGFloat = 3
        let body = NSRect(x: 0, y: 0, width: bounds.width - tipW - 1, height: bounds.height)
        let shape = NSBezierPath(roundedRect: body, xRadius: 5, yRadius: 5)
        NSColor(white: 1, alpha: 0.28).setFill(); shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        color.setFill()
        let f = min(max(fraction, 0), 1)
        NSRect(x: 0, y: 0, width: f > 0 ? max(5, body.width * f) : 0, height: body.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: bounds.midY - 2.5, width: tipW, height: 5), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Circular progress ring (AirPods battery).
final class RingView: NSView {
    private let track = CAShapeLayer(), prog = CAShapeLayer()
    var fraction: CGFloat = 0 {
        didSet {
            guard fraction != oldValue else { return }
            let from = prog.presentation()?.strokeEnd ?? prog.strokeEnd
            let to = min(max(fraction, 0), 1)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            prog.strokeEnd = to; CATransaction.commit()
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = from; a.toValue = to; a.duration = 0.4
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            prog.add(a, forKey: "level")
        }
    }
    var color: NSColor = bannerGreen { didSet { prog.strokeColor = color.cgColor } }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for l in [track, prog] { l.fillColor = nil; l.lineWidth = 3.5; l.lineCap = .round; layer?.addSublayer(l) }
        track.strokeColor = NSColor(white: 1, alpha: 0.22).cgColor
        prog.strokeColor = color.cgColor
        prog.strokeEnd = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 2.5,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)   // from the top, clockwise
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [track, prog] { l.frame = bounds; l.path = path }
        CATransaction.commit()
    }
}

/// The original HUD's bar: 16 flat cells; while the pointer is over the HUD they melt into a smooth slider with a
/// knob. Eased fill; click or drag sets the level. The view is tall (easy to hit) but draws thin.
final class LevelBar: NSView {
    private static let count = 16
    private static let knobW: CGFloat = 18, knobH: CGFloat = 14, lineH: CGFloat = 4
    private let seg = CALayer(), slider = CALayer()
    private var track: [CALayer] = [], fill: [CALayer] = []
    private let sTrack = CALayer(), sFill = CALayer(), knob = CALayer()
    private var shown: Float = 0, target: Float = 0
    private var timer: Timer?
    var onChange: ((Float) -> Void)?

    /// Pointer over the HUD: cells -> slider with a knob.
    var sliderMode = false {
        didSet {
            guard sliderMode != oldValue else { return }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            seg.opacity = sliderMode ? 0 : 1
            slider.opacity = sliderMode ? 1 : 0
            CATransaction.commit()
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(seg); layer?.addSublayer(slider)
        for _ in 0..<LevelBar.count {
            let t = CALayer(); t.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor; t.cornerRadius = 1.5; t.masksToBounds = true
            let f = CALayer(); f.backgroundColor = NSColor(white: 1, alpha: 0.95).cgColor
            t.addSublayer(f); seg.addSublayer(t); track.append(t); fill.append(f)
        }
        sTrack.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor; sTrack.cornerRadius = LevelBar.lineH / 2
        sFill.backgroundColor = NSColor(white: 1, alpha: 0.95).cgColor;  sFill.cornerRadius = LevelBar.lineH / 2
        knob.backgroundColor = NSColor.white.cgColor; knob.cornerRadius = LevelBar.knobH / 2
        knob.shadowColor = NSColor.black.cgColor; knob.shadowOpacity = 0.35; knob.shadowRadius = 2; knob.shadowOffset = .zero
        slider.addSublayer(sTrack); slider.addSublayer(sFill); slider.addSublayer(knob)
        slider.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { Double(target) }
    override func accessibilityMinValue() -> Any? { 0.0 }
    override func accessibilityMaxValue() -> Any? { 1.0 }
    override func accessibilityPerformIncrement() -> Bool { adjust(1.0 / 16); return true }
    override func accessibilityPerformDecrement() -> Bool { adjust(-1.0 / 16); return true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { adjust(-1.0 / 16) }
        else if event.keyCode == 124 { adjust(1.0 / 16) }
        else { super.keyDown(with: event) }
    }
    private func adjust(_ delta: Float) {
        let value = min(1, max(0, target + delta)); set(value, animated: false); onChange?(value)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() { super.layout(); render() }

    private func render() {
        let n = CGFloat(LevelBar.count), gap: CGFloat = 2, mid = bounds.height / 2
        let cw = (bounds.width - gap * (n - 1)) / n, ch = LevelBar.lineH
        let kw = LevelBar.knobW, kh = LevelBar.knobH
        CATransaction.begin(); CATransaction.setDisableActions(true)
        seg.frame = bounds; slider.frame = bounds
        for i in 0..<LevelBar.count {
            track[i].frame = CGRect(x: CGFloat(i) * (cw + gap), y: mid - ch / 2, width: cw, height: ch)
            let frac = CGFloat(min(max(shown * Float(LevelBar.count) - Float(i), 0), 1))
            fill[i].frame = CGRect(x: 0, y: 0, width: cw * frac, height: ch)
        }
        let cx = kw / 2 + CGFloat(shown) * max(bounds.width - kw, 0)
        sTrack.frame = CGRect(x: 0, y: mid - ch / 2, width: bounds.width, height: ch)
        sFill.frame = CGRect(x: 0, y: mid - ch / 2, width: cx, height: ch)
        knob.frame = CGRect(x: cx - kw / 2, y: mid - kh / 2, width: kw, height: kh)
        CATransaction.commit()
    }

    /// Eased towards the new value; `animated: false` jumps (used while the pointer drags).
    func set(_ v: Float, animated: Bool) {
        target = min(max(v, 0), 1)
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { shown = target; timer?.invalidate(); timer = nil; render(); return }
        guard timer == nil, abs(shown - target) > 0.002 else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let s = self else { tm.invalidate(); return }
            s.shown += (s.target - s.shown) * 0.3
            if abs(s.target - s.shown) < 0.002 { s.shown = s.target; tm.invalidate(); s.timer = nil }
            s.render()
        }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func pick(_ e: NSEvent) {
        let x = convert(e.locationInWindow, from: nil).x, w = max(bounds.width, 1)
        let frac = sliderMode ? (x - LevelBar.knobW / 2) / max(w - LevelBar.knobW, 1) : x / w   // knob centre follows the pointer
        let v = (Float(frac) * 64).rounded() / 64                                          // 1/64 grid
        set(v, animated: false)
        onChange?(min(max(v, 0), 1))
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }
}

/// The timer's icon: a ring with a small glyph inside. A stopwatch's ring fills up (one lap per minute); a countdown's ring
/// shrinks as the time runs out.
final class TimerRing: NSView {
    private let track = CAShapeLayer(), prog = CAShapeLayer()
    private let glyph = NSImageView()
    private var glyphName = ""
    var fraction: CGFloat = 0 {
        didSet {
            guard abs(fraction - oldValue) > 0.0005 else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)       // no easing: a lap wraps around instantly
            prog.strokeEnd = min(max(fraction, 0), 1)
            CATransaction.commit()
        }
    }
    var countdown = false {
        didSet {
            let name = countdown ? "hourglass" : "stopwatch"
            guard name != glyphName else { return }
            glyphName = name
            glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        }
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for l in [track, prog] { l.fillColor = nil; l.lineWidth = 2.4; l.lineCap = .round; layer?.addSublayer(l) }
        track.strokeColor = accent.withAlphaComponent(0.25).cgColor
        prog.strokeColor = accent.cgColor
        prog.strokeEnd = 0
        glyph.contentTintColor = accent
        addSubview(glyph)
        countdown = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: min(bounds.width, bounds.height) / 2 - 2.2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)      // from the top, clockwise
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [track, prog] { l.frame = bounds; l.path = path }
        CATransaction.commit()
        glyph.frame = bounds
    }
}

/// A wheel seen edge-on under the island. There is an invisible circle with its centre inside the island; the ticks stand on
/// its rim and point outwards. The rim bulges out below the island in the middle and tucks back in behind the island at both
/// ends, so the dial looks wrapped onto the island. (This view sits behind the island's black body, which hides the ends.)
/// One long tick per live activity; the wheel goes round without an end, so the activities repeat on it.
final class DialView: NSView {
    static let perMajor = 6                                  // minor ticks between two activities
    static let gap: CGFloat = 11                             // distance between ticks along the rim
    static let radius: CGFloat = 230                         // radius of the invisible circle
    static let bulge: CGFloat = 38                           // how far the rim hangs below the island's bottom edge
    struct Geometry { var body = NSRect.zero }
    var geometry = Geometry() { didSet { relayout() } }
    private var ticks: [CALayer] = []
    var count = 1 { didSet { if count != oldValue { relayout() } } }
    private(set) var position: CGFloat = 0                   // in activities: 0 = the first, 1 = the second...
    private var target: CGFloat = 0
    private var velocity: CGFloat = 0
    private var timer: Timer?
    /// Light mode: dark ticks. Dark mode: light ticks. (Each tick also has an outline of the opposite colour, so it reads on
    /// any background without the screen having to be looked at.)
    var lightAppearance = false { didSet { if lightAppearance != oldValue { relayout() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<60 {
            let l = CALayer()
            l.borderWidth = 1
            l.cornerRadius = 2.2
            l.shadowColor = NSColor.black.cgColor; l.shadowOpacity = 0.3; l.shadowRadius = 2; l.shadowOffset = .zero
            l.bounds = CGRect(x: 0, y: 0, width: 4.4, height: 14)
            layer?.addSublayer(l); ticks.append(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); relayout() }

    /// Click and drag on the ticks turns the wheel: (pointer movement in points, phase 0 = down, 1 = move, 2 = up).
    var onDrag: ((CGFloat, Int) -> Void)?
    override func hitTest(_ p: NSPoint) -> NSView? {
        let b = geometry.body
        guard alphaValue > 0.3, !isHidden, p.y < b.minY + 2, p.y > b.minY - DialView.bulge - 14,
              p.x > b.minX - 24, p.x < b.maxX + 24 else { return nil }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var lastX: CGFloat = 0
    override func mouseDown(with event: NSEvent) { lastX = event.locationInWindow.x; onDrag?(0, 0) }
    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX, 1); lastX = x
    }
    override func mouseUp(with event: NSEvent) { onDrag?(0, 2) }

    /// Moves the wheel to `t` (in activities). A finger turning it sets it directly; otherwise it springs there.
    func set(_ t: CGFloat, animated: Bool) {
        target = t
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { position = t; velocity = 0; timer?.invalidate(); timer = nil; relayout(); return }
        guard timer == nil, abs(position - target) > 0.0008 || abs(velocity) > 0.01 else { return }
        let dt: CGFloat = 1.0 / 60
        let tm = Timer(timeInterval: Double(dt), repeats: true) { [weak self] tm in
            guard let s = self else { tm.invalidate(); return }
            s.velocity += (-230 * (s.position - s.target) - 25 * s.velocity) * dt        // a soft spring, a touch of overshoot
            s.position += s.velocity * dt
            if abs(s.position - s.target) < 0.0008 && abs(s.velocity) < 0.01 { s.position = s.target; s.velocity = 0; tm.invalidate(); s.timer = nil }
            s.relayout()
        }
        RunLoop.main.add(tm, forMode: .common); timer = tm
    }

    private func relayout() {
        let body = geometry.body
        guard body.width > 0 else { return }
        let R = DialView.radius, g = DialView.bulge
        let c = CGPoint(x: body.midX, y: body.minY + (R - g))             // the circle's centre, inside the island
        let thetaMax = acos(1 - g / R)                                      // where the rim comes back up to the island's bottom edge
        let gap = DialView.gap, per = DialView.perMajor
        let unit = CGFloat(per) * gap
        let first = Int(floor((position * unit - R * thetaMax) / gap)) - 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in ticks.enumerated() {
            let k = first + i
            let th = (CGFloat(k) * gap - position * unit) / R               // angle from straight down; ticks are spaced evenly on the rim
            guard abs(th) < thetaMax else { l.isHidden = true; continue }
            let n = CGPoint(x: sin(th), y: -cos(th))                        // outwards from the centre
            let edge = abs(th) / thetaMax                                   // 0 in the middle ... 1 where it tucks in
            let major = ((k % per) + per) % per == 0                        // the wheel goes round: the activities repeat on it
            let selected = major && abs(CGFloat(k / per) - position) < 0.5
            let len = (major ? 22 : 12) * (1 - 0.3 * edge)
            let mid = R - 3 + len / 2                                       // a tick starts just inside the rim and points outwards
            l.backgroundColor = NSColor(white: lightAppearance ? 0.1 : 1, alpha: 1).cgColor
            l.borderColor = NSColor(white: lightAppearance ? 1 : 0, alpha: 0.85).cgColor
            l.isHidden = false
            l.bounds = CGRect(x: 0, y: 0, width: 4.4, height: len + 2)
            l.position = CGPoint(x: c.x + n.x * mid, y: c.y + n.y * mid)
            l.transform = CATransform3DMakeRotation(atan2(n.y, n.x) + .pi / 2, 0, 0, 1)
            l.opacity = Float(pow(cos(edge * .pi / 2), 0.8) * (major ? (selected ? 1 : 0.7) : 0.5))
        }
        CATransaction.commit()
    }
}

func makeLabel(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, mono: Bool = false,
               align: NSTextAlignment = .left) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = align
    l.isBezeled = false
    l.lineBreakMode = .byTruncatingTail
    return l
}

func makeSymbolButton(_ name: String, _ pt: CGFloat, _ tint: NSColor) -> NSButton {
    let b = FeedbackButton()
    b.isBordered = false
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleNone
    b.contentTintColor = tint
    b.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pt, weight: .bold))
    return b
}

func setSymbol(_ b: NSButton, _ name: String, _ pt: CGFloat) {
    b.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pt, weight: .bold))
}


/// A subtle hover surface and a short press response keep icon-only controls discoverable.
final class FeedbackButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovering || isHighlighted) {
            NSColor(white: 1, alpha: isHighlighted ? 0.22 : 0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
        }
        super.draw(dirtyRect)
    }
    override func highlight(_ flag: Bool) {
        super.highlight(flag); needsDisplay = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        wantsLayer = true
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = flag ? 1 : 0.94; animation.toValue = flag ? 0.94 : 1
        animation.duration = 0.12
        layer?.add(animation, forKey: "buttonPress")
    }
}
