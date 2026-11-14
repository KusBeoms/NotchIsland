import AppKit
import CoreText

/// Each composed character is drawn as one rigid glyph group. Colour gradients never split its geometry.
final class LyricRowView: NSView {
    private struct Placement {
        var font: CTFont
        var glyph: CGGlyph
        var position: CGPoint
        var stringIndex: Int
    }
    private struct CharacterInk {
        var rect: CGRect
        var mask: CGImage
        var timing: LyricsWord?
        var forward: Bool
    }
    private var lyric = LyricsLine(start: 0, end: nil, text: "")
    private var timings: [LyricsWord] = []
    private var characters: [CharacterInk] = []
    private var cachedWidth: CGFloat = -1
    private var cachedScale: CGFloat = 0
    private var maximumLines = 2
    private var time: TimeInterval = 0
    private var emphasis: Double = 1
    private let characterRiseDuration: Double = 0.32
    private var gradient: CGGradient?
    private var gradientEmphasis = -1.0
    private var activeWindow: ClosedRange<TimeInterval>?   // outside it, progress and lift cannot change
    private var phase = -1
    private(set) var wordProgress: [Double] = []
    private(set) var characterLifts: [Double] = []
    var lineIndex = 0
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ line: LyricsLine, maximumLines: Int) {
        guard lyric != line || self.maximumLines != maximumLines else { return }
        lyric = line; timings = line.characterTimings; self.maximumLines = maximumLines; cachedWidth = -1
        wordProgress = []; characterLifts = []; needsDisplay = true; phase = -1
        activeWindow = timings.isEmpty ? nil : (timings.map(\.start).min()!...(timings.map(\.end).max()! + characterRiseDuration))
    }
    func advance(to time: TimeInterval, emphasis: Double) {
        // Lines that are not being sung only redraw when their emphasis changes (while the list scrolls).
        let newPhase = activeWindow.map { time < $0.lowerBound ? 0 : (time > $0.upperBound ? 2 : 1) } ?? 3
        if newPhase != 1, newPhase == phase, self.emphasis == emphasis { self.time = time; return }
        phase = newPhase
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let progress = lyric.words.map { $0.progress(at: time) }
        let lifts = timings.map { $0.lift(at: time, emphasis: emphasis, reduceMotion: reduceMotion, minimumRiseDuration: characterRiseDuration) }
        let changed = progress != wordProgress || lifts != characterLifts || self.emphasis != emphasis
        self.time = time; self.emphasis = emphasis; wordProgress = progress; characterLifts = lifts
        if changed { needsDisplay = true }
    }
    override func layout() { super.layout(); if cachedWidth != bounds.width { needsDisplay = true } }
    private func shapeText() {
        cachedWidth = bounds.width; cachedScale = window?.backingScaleFactor ?? 2
        characters = []
        guard bounds.width > 6, !lyric.text.isEmpty else { return }
        let text = NSAttributedString(string: lyric.text, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .ligature: 0,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: bounds.width - 6, height: 1000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let count = min(maximumLines, lines.count)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(lines[0], &ascent, nil, nil)
        _ = CTLineGetTypographicBounds(lines[count - 1], nil, &descent, nil)
        let shift = (bounds.height - (origins[0].y + ascent - origins[count - 1].y + descent)) / 2 - (origins[count - 1].y - descent)
        let string = lyric.text as NSString
        for lineIndex in 0..<count {
            let origin = CGPoint(x: origins[lineIndex].x + 3, y: origins[lineIndex].y + shift)
            let lineRange = CTLineGetStringRange(lines[lineIndex])
            var placements: [Placement] = []
            for run in CTLineGetGlyphRuns(lines[lineIndex]) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let font = attributes[kCTFontAttributeName] else { continue }
                let ctFont = font as! CTFont
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for i in 0..<count where indices[i] >= 0 && indices[i] < string.length {
                    placements.append(Placement(font: ctFont, glyph: glyphs[i],
                                                position: CGPoint(x: positions[i].x + origin.x, y: positions[i].y + origin.y), stringIndex: indices[i]))
                }
            }
            let starts = Set(placements.map(\.stringIndex)).sorted()
            var groups: [NSRange] = []
            for (offset, start) in starts.enumerated() {
                let composed = string.rangeOfComposedCharacterSequence(at: start)
                let next = offset + 1 < starts.count ? starts[offset + 1] : lineRange.location + lineRange.length
                let end = min(string.length, max(NSMaxRange(composed), next))
                let range = NSRange(location: composed.location, length: end - composed.location)
                // Combining marks, emoji sequences and mandatory ligature clusters remain one rigid unit.
                if let previous = groups.last, NSMaxRange(previous) > range.location {
                    groups[groups.count - 1] = NSUnionRange(previous, range)
                } else { groups.append(range) }
            }
            for range in groups {
                let glyphs = placements.filter { NSLocationInRange($0.stringIndex, range) }
                var ink = CGRect.null
                for placement in glyphs {
                    var glyph = placement.glyph
                    let rect = CTFontGetBoundingRectsForGlyphs(placement.font, .default, &glyph, nil, 1)
                        .offsetBy(dx: placement.position.x, dy: placement.position.y)
                    if !rect.isEmpty { ink = ink.union(rect) }
                }
                guard !ink.isNull, ink.width > 0, ink.height > 0 else { continue }
                let pad = 1 / cachedScale
                let minX = floor((ink.minX - pad) * cachedScale) / cachedScale
                let minY = floor((ink.minY - pad) * cachedScale) / cachedScale
                let maxX = ceil((ink.maxX + pad) * cachedScale) / cachedScale
                let maxY = ceil((ink.maxY + pad) * cachedScale) / cachedScale
                let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                guard let bitmap = CGContext(data: nil, width: max(1, Int(ceil(rect.width * cachedScale))),
                                             height: max(1, Int(ceil(rect.height * cachedScale))), bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                bitmap.scaleBy(x: cachedScale, y: cachedScale)
                bitmap.translateBy(x: -rect.minX, y: -rect.minY)
                bitmap.setFillColor(NSColor.white.cgColor)
                for placement in glyphs {
                    var glyph = placement.glyph, position = placement.position
                    CTFontDrawGlyphs(placement.font, &glyph, &position, 1, bitmap)
                }
                guard let mask = bitmap.makeImage() else { continue }
                let matched = timings.filter { NSIntersectionRange($0.range, range).length > 0 }
                let timing = matched.first.map { first in
                    LyricsWord(start: matched.map(\.start).min() ?? first.start,
                               end: matched.map(\.end).max() ?? first.end, range: range)
                }
                let left = CTLineGetOffsetForStringIndex(lines[lineIndex], range.location, nil)
                let right = CTLineGetOffsetForStringIndex(lines[lineIndex], NSMaxRange(range), nil)
                characters.append(CharacterInk(rect: rect, mask: mask, timing: timing, forward: right >= left))
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if cachedWidth != bounds.width || cachedScale != (window?.backingScaleFactor ?? 2) { shapeText() }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let baseAlpha = lyric.words.isEmpty ? 0.65 + 0.35 * emphasis : 0.7 - 0.35 * emphasis
        if gradient == nil || gradientEmphasis != emphasis {
            let colors = [NSColor(white: 1, alpha: 0.65 + 0.35 * emphasis).cgColor, NSColor(white: 1, alpha: baseAlpha).cgColor] as CFArray
            gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            gradientEmphasis = emphasis
        }
        let fillColor = NSColor(white: 1, alpha: baseAlpha).cgColor
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for character in characters {
            let progress = character.timing?.progress(at: time) ?? 0
            let lift = character.timing?.lift(at: time, emphasis: emphasis, reduceMotion: reduceMotion, minimumRiseDuration: characterRiseDuration) ?? 0
            context.saveGState()
            // One translation applies to the entire character, including both dim and bright portions.
            context.translateBy(x: 0, y: lift)
            context.clip(to: character.rect, mask: character.mask)
            if progress > 0 {
                let feather = min(8, max(3, character.rect.width * 0.3))
                let direction: CGFloat = character.forward ? 1 : -1
                let leading = character.forward ? character.rect.minX : character.rect.maxX
                let front = leading + direction * (CGFloat(progress) * (character.rect.width + 2 * feather) - feather)
                if let gradient {
                    context.drawLinearGradient(gradient,
                        start: CGPoint(x: front - direction * feather, y: character.rect.midY),
                        end: CGPoint(x: front + direction * feather, y: character.rect.midY),
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                } else {
                    context.setFillColor(fillColor); context.fill(character.rect)
                }
            } else {
                context.setFillColor(fillColor); context.fill(character.rect)
            }
            context.restoreGState()
        }
    }
}

final class LyricsWaitView: NSView {
    private var brightness = [Double](repeating: 0.18, count: 3)
    func advance(to time: Double, start: Double, end: Double) {
        let next = LyricsTimeline.dotBrightness(at: time, start: start, end: end)
        if next != brightness { brightness = next; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for index in 0..<3 {
            NSColor(white: 1, alpha: brightness[index]).setFill()
            NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * 14, y: bounds.midY - 4, width: 8, height: 8)).fill()
        }
    }
}

final class LyricsCreditsView: Flip {
    let label = makeLabel(14, .regular, NSColor(white: 1, alpha: 0.55))
    init(names: [String]) {
        super.init(frame: .zero)
        let text = names.isEmpty ? "작사 정보 없음" : "작사: " + names.joined(separator: ", ")
        let value = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14),
                                                                        .foregroundColor: NSColor(white: 1, alpha: 0.55)])
        if !names.isEmpty { value.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .semibold), range: NSRange(location: 0, length: 3)) }
        label.attributedStringValue = value
        label.maximumNumberOfLines = 2; label.lineBreakMode = .byWordWrapping; label.cell?.wraps = true
        label.toolTip = text
        addSubview(label); wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: 1000)).height ?? 20
        let height = min(bounds.height, max(20, measured))
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }
}

/// Text stays at a fixed width; only the viewport moves. No NSView frame animations can be cancelled by layout.
final class LyricsPanelView: Flip {
    private let title = makeLabel(14, .medium, .white)
    private let detail = makeLabel(12, .medium, NSColor(white: 1, alpha: 0.45))
    private let divider = CALayer()
    private let edgeFade = CAGradientLayer()
    private var state: LyricsState?
    private var document: LyricsDocument?
    private var timeline: LyricsTimeline?
    private var duration: Double?
    private var rows: [Int: NSView] = [:]
    private var lastTime: TimeInterval?
    private var lastFrameTime: TimeInterval?
    private var lastPosition: Double?
    private var stateVersion: Int?
    /// True once the scroll follower has reached its target: a paused song needs no more frames.
    private(set) var settled = false
    private var accessibilityIndex: Int?
    private var scroll = LyricsScrollFollower()
    var position: Double { scroll.position }
    private(set) var rowSpacing: CGFloat = 40
    private var anchorIndex = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        divider.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.addSublayer(divider)
        edgeFade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        edgeFade.locations = [0, 0.06, 0.94, 1]
        layer?.mask = edgeFade
        for label in [title, detail] {
            label.maximumNumberOfLines = 2; label.lineBreakMode = .byWordWrapping; label.cell?.wraps = true
            addSubview(label)
        }
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        edgeFade.frame = bounds
        divider.frame = CGRect(x: 0, y: 4, width: 1, height: max(0, bounds.height - 8))
        CATransaction.commit()
        rowSpacing = min(40, max(28, (bounds.height - 32) / 2))
        title.frame = NSRect(x: 18, y: max(0, bounds.midY - 34), width: max(0, bounds.width - 36), height: 42)
        detail.frame = NSRect(x: 18, y: bounds.midY + 14, width: max(0, bounds.width - 36), height: 36)
        positionRows()
    }
    /// `version` (LyricsController.version) replaces the deep comparison of a whole document. `advance: false` leaves the
    /// per-frame motion to the display loop and only applies a changed state.
    func update(_ state: LyricsState, version: Int? = nil, time: TimeInterval, duration: Double? = nil,
                frameTime: Double = hardwareSeconds(), advance: Bool = true) {
        let changed = self.duration != duration || (version.map { $0 != stateVersion } ?? (self.state != state))
        if changed {
            self.state = state; self.duration = duration; stateVersion = version
            lastPosition = nil; settled = false
            rows.values.forEach { $0.removeFromSuperview() }; rows.removeAll()
            document = nil; timeline = nil; lastTime = nil; lastFrameTime = nil; accessibilityIndex = nil
            title.isHidden = false; detail.isHidden = false
            switch state {
            case .idle, .loading:
                title.stringValue = "가사를 불러오는 중…"; detail.stringValue = "Apple Music"
            case .missing:
                title.stringValue = "음악 앱에서 가사를 열어 주세요"; detail.stringValue = "가사가 준비되면 자동으로 표시합니다"
            case .failed:
                title.stringValue = "가사 캐시를 읽을 수 없습니다"; detail.stringValue = "잠시 후 다시 확인합니다"
            case .document(let document):
                if document.lines.isEmpty {
                    title.stringValue = document.plainText; title.toolTip = document.plainText
                    detail.stringValue = "시간 정보 없는 가사"
                } else {
                    self.document = document; timeline = LyricsTimeline(document: document, duration: duration)
                    title.isHidden = true; detail.isHidden = true
                }
            }
            if document == nil { setAccessibilityLabel(title.stringValue + ". " + detail.stringValue) }
        }
        if changed || advance { self.advance(to: time, frameTime: frameTime) }
    }
    /// The display loop only needs to call `advance` while the song moves or the list is still scrolling.
    func needsAdvance(at time: TimeInterval) -> Bool { document != nil && (!settled || lastTime != time) }
    func advance(to time: TimeInterval, frameTime: Double = hardwareSeconds()) {
        guard let document, let timeline, !timeline.slots.isEmpty else { return }
        let target = timeline.position(at: time)
        let playbackDelta = time - (lastTime ?? time)
        if lastFrameTime == nil || playbackDelta < -0.1 || playbackDelta > 1 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            scroll.reset(to: target)
        } else { scroll.advance(toward: target, deltaTime: frameTime - (lastFrameTime ?? frameTime)) }
        settled = position == target
        if let lastTime, lastTime == time, lastPosition == position, !rows.isEmpty {
            lastFrameTime = frameTime; return                 // nothing moved: skip the row work
        }
        lastPosition = position
        anchorIndex = min(timeline.slots.count - 1, max(0, Int(position.rounded())))
        let needed = Set(max(0, anchorIndex - 1)...min(timeline.slots.count - 1, anchorIndex + 1))
        for index in needed where rows[index] == nil {
            let row: NSView
            switch timeline.slots[index].kind {
            case .line(let lineIndex):
                let lyric = LyricRowView(frame: .zero); lyric.lineIndex = index
                // Every sentence is shaped once at the same font and width, including its off-centre states.
                lyric.configure(document.lines[lineIndex], maximumLines: 2); row = lyric
            case .waiting: row = LyricsWaitView(frame: .zero)
            case .credits: row = LyricsCreditsView(names: document.songwriters)
            }
            row.wantsLayer = true; addSubview(row); rows[index] = row
        }
        for (index, row) in rows {
            if let row = row as? LyricRowView { row.advance(to: time, emphasis: max(0, 1 - abs(Double(index) - position))) }
            if let row = row as? LyricsWaitView, let end = timeline.slots[index].end {
                row.advance(to: time, start: timeline.slots[index].start, end: end)
            }
        }
        if rows.count > needed.count {
            for index in rows.keys.filter({ !needed.contains($0) }) { rows[index]?.removeFromSuperview(); rows.removeValue(forKey: index) }
        }
        positionRows()
        let activeSlot = timeline.index(at: time)
        if accessibilityIndex != activeSlot {
            accessibilityIndex = activeSlot
            switch timeline.slots[activeSlot].kind {
            case .line(let index): setAccessibilityLabel(document.lines[index].text)
            case .waiting: setAccessibilityLabel("다음 가사를 기다리는 중")
            case .credits: setAccessibilityLabel(document.songwriters.isEmpty ? "작사 정보 없음" : "작사: " + document.songwriters.joined(separator: ", "))
            }
        }
        lastTime = time; lastFrameTime = frameTime
    }
    private func positionRows() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, row) in rows {
            let creditInset: CGFloat = row is LyricsCreditsView ? 10 : 0
            let frame = NSRect(x: 18, y: bounds.midY + CGFloat(Double(index) - position) * rowSpacing - 22 + creditInset,
                               width: max(0, bounds.width - 36), height: 44)
            if row.frame != frame { row.frame = frame }
            let alpha = 1 - 0.55 * min(1, CGFloat(abs(Double(index) - position)))
            if row.alphaValue != alpha { row.alphaValue = alpha }
        }
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, !isHidden, alphaValue > 0.3 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
