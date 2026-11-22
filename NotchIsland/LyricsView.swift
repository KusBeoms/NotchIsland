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
    private(set) var pageOffsets: [(start: Double, offset: CGFloat)] = []
    private var cachedWidth: CGFloat = -1
    private var cachedScale: CGFloat = 0
    private var maximumLines = 2
    private var time: TimeInterval = 0
    private var emphasis: Double = 1
    private var motionGain = 1.0
    private var pageScroll = LyricsScrollFollower(maximumSpeed: 240)
    private var lastMotionFrame: Double?
    private var completedPausedPage: (start: Double, offset: CGFloat)?
    var displayedPageOffset: Double { pageScroll.position }
    private(set) var pageSettled = true
    private let characterRiseDuration: Double = 0.32
    private static let waveReach = 4          // how many preceding characters still pull a character along
    private static let waveDelay = 0.05       // seconds of lag per character: the lift spreads like a wave
    private static let waveDecay = 0.55
    private var gradient: CGGradient?
    private var gradientEmphasis = -1.0
    private(set) var wordProgress: [Double] = []
    private(set) var characterLifts: [Double] = []
    private(set) var characterScales: [Double] = []
    var topOcclusion: CGFloat = 0 { didSet { if oldValue != topOcclusion { needsDisplay = true } } }
    var lineIndex = 0
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ line: LyricsLine, maximumLines: Int) {
        guard lyric != line || self.maximumLines != maximumLines else { return }
        lyric = line; timings = line.characterTimings; self.maximumLines = maximumLines; cachedWidth = -1
        wordProgress = []; characterLifts = []; characterScales = []; pageOffsets = []; needsDisplay = true
        lastMotionFrame = nil; completedPausedPage = nil; pageSettled = true
    }
    func advance(to time: TimeInterval, emphasis: Double, motionGain: Double = 1, playing: Bool = true,
                 frameTime: Double? = nil, resetMotion: Bool = false) {
        if cachedWidth != bounds.width || cachedScale != (window?.backingScaleFactor ?? 2) { shapeText() }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let previousPage = pageScroll.position
        var targetPage = pageOffset(at: time, reduceMotion: reduceMotion)
        if resetMotion { completedPausedPage = nil }
        // If a page turn has begun, finish that turn after pause without starting later pages.
        if !playing, let next = pageOffsets.dropFirst().first(where: { $0.start > time }),
           time > next.start - min(0.2, max(0.01, next.start - lyric.start)) {
            completedPausedPage = next
        }
        if let completed = completedPausedPage {
            // Resume from the finished page; do not turn backwards before playback catches up.
            if time < completed.start { targetPage = max(targetPage, completed.offset) }
            else { completedPausedPage = nil }
        }
        if let frameTime, let lastMotionFrame, !resetMotion, !reduceMotion {
            pageScroll.advance(toward: Double(targetPage), deltaTime: frameTime - lastMotionFrame)
        } else { pageScroll.reset(to: Double(targetPage)) }
        lastMotionFrame = frameTime
        pageSettled = pageScroll.position == Double(targetPage)
        let progress = lyric.words.map { $0.progress(at: time) }
        let lifts = draggedLifts(for: timings, emphasis: emphasis, at: time, reduceMotion: reduceMotion).map { $0 * motionGain }
        let scales = timings.map { 1 + ($0.scale(at: time, emphasis: emphasis, reduceMotion: reduceMotion, minimumRiseDuration: characterRiseDuration) - 1) * motionGain }
        let changed = progress != wordProgress || lifts != characterLifts || scales != characterScales || self.emphasis != emphasis
            || self.motionGain != motionGain || previousPage != pageScroll.position
        self.time = time; self.emphasis = emphasis; self.motionGain = motionGain
        wordProgress = progress; characterLifts = lifts; characterScales = scales
        if changed { needsDisplay = true }
    }
    /// Every character rises on its own timing; the characters behind it are pulled along with a decaying share,
    /// so the line moves like a cloud instead of as separate hops.
    /// Each following character receives the earlier characters' lift a little later and weaker (a stateless wave),
    /// blended so the total never exceeds the peak and stays continuous in time.
    private func draggedLifts(for words: [LyricsWord?], emphasis: Double, at time: TimeInterval, reduceMotion: Bool) -> [Double] {
        let peak = LyricsWord.liftPeak
        func own(_ index: Int, _ time: TimeInterval) -> Double {
            words[index]?.lift(at: time, emphasis: emphasis, reduceMotion: reduceMotion, minimumRiseDuration: characterRiseDuration) ?? 0
        }
        return words.indices.map { index in
            var pulled = 0.0
            for distance in 1...Self.waveReach where index - distance >= 0 {
                pulled += pow(Self.waveDecay, Double(distance)) * own(index - distance, time - Self.waveDelay * Double(distance))
            }
            let own = own(index, time)
            return own + (1 - min(1, own / peak)) * peak * tanh(pulled / peak)
        }
    }
    override func layout() { super.layout(); if cachedWidth != bounds.width { needsDisplay = true } }
    private func shapeText() {
        cachedWidth = bounds.width; cachedScale = window?.backingScaleFactor ?? 2
        characters = []; pageOffsets = []; completedPausedPage = nil; lastMotionFrame = nil
        guard bounds.width > 6, !lyric.text.isEmpty else { return }
        let text = NSAttributedString(string: lyric.text, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .ligature: 0,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: bounds.width - 6, height: CGFloat(lyric.text.utf16.count + 1) * 24), transform: nil)
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
        for page in stride(from: 0, to: lines.count, by: max(1, maximumLines)) {
            let range = CTLineGetStringRange(lines[page])
            let timing = timings.first { NSLocationInRange($0.range.location, NSRange(location: range.location, length: range.length)) }
            let fraction = Double(range.location) / Double(max(1, (lyric.text as NSString).length))
            let start = timing?.start ?? (lyric.start + fraction * max(0.01, (lyric.end ?? lyric.start + 5) - lyric.start))
            pageOffsets.append((start, origins[0].y - origins[page].y))
        }
        for lineIndex in lines.indices {
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
                               end: matched.map(\.end).max() ?? first.end, range: range,
                               spanHint: matched.compactMap(\.spanHint).max())
                }
                let left = CTLineGetOffsetForStringIndex(lines[lineIndex], range.location, nil)
                let right = CTLineGetOffsetForStringIndex(lines[lineIndex], NSMaxRange(range), nil)
                characters.append(CharacterInk(rect: rect, mask: mask, timing: timing, forward: right >= left))
            }
        }
    }
    /// Advance through every pair of wrapped lines rather than discarding text after line two.
    func pageOffset(at time: Double, reduceMotion: Bool) -> CGFloat {
        var previous: CGFloat = 0
        for page in pageOffsets.dropFirst() {
            if time >= page.start { previous = page.offset; continue }
            let transition = min(0.2, max(0.01, page.start - lyric.start))
            let progress = LyricsWord.smoothstep((time - page.start + transition) / transition)
            return reduceMotion ? previous : previous + (page.offset - previous) * CGFloat(progress)
        }
        return previous
    }
    private func characterScale(_ timing: LyricsWord?, reduceMotion: Bool) -> CGFloat {
        let scale = timing?.scale(at: time, emphasis: emphasis, reduceMotion: reduceMotion, minimumRiseDuration: characterRiseDuration) ?? 1
        return CGFloat(1 + (scale - 1) * motionGain)
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
        let pageMargin: CGFloat = pageOffsets.count > 1 ? 4 : 0
        let visibleTop = min(bounds.height - pageMargin, bounds.height - topOcclusion)
        context.clip(to: CGRect(x: 0, y: pageMargin, width: bounds.width, height: max(0, visibleTop - pageMargin)))
        context.translateBy(x: 0, y: lastMotionFrame == nil ? pageOffset(at: time, reduceMotion: reduceMotion) : CGFloat(pageScroll.position))
        let lifts = draggedLifts(for: characters.map(\.timing), emphasis: emphasis, at: time, reduceMotion: reduceMotion)
        for (index, character) in characters.enumerated() {
            let progress = character.timing?.progress(at: time) ?? 0
            let lift = lifts[index] * motionGain
            context.saveGState()
            context.interpolationQuality = .high
            // One translation applies to the entire character, including both dim and bright portions.
            context.translateBy(x: 0, y: lift)
            let swell = characterScale(character.timing, reduceMotion: reduceMotion)
            if swell != 1 {
                context.translateBy(x: character.rect.midX, y: character.rect.minY)   // grow from the bottom centre: no vertical wobble
                context.scaleBy(x: swell, y: swell)
                context.translateBy(x: -character.rect.midX, y: -character.rect.minY)
            }
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
    let label = makeLabel(14, .regular, NSColor(white: 1, alpha: Tone.secondary))
    init(names: [String]) {
        super.init(frame: .zero)
        let text = names.isEmpty ? "작사 정보 없음" : "작사: " + names.joined(separator: ", ")
        let value = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14),
                                                                        .foregroundColor: NSColor(white: 1, alpha: Tone.secondary)])
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
    private let detail = makeLabel(12, .medium, NSColor(white: 1, alpha: Tone.secondary))
    private let fullTextScroll = NSScrollView()
    private let fullText = NSTextView()
    let readingButton = NSButton(title: "전문 보기", target: nil, action: nil)
    let reloadButton = NSButton(title: "", target: nil, action: nil)
    var onReload: (() -> Void)?
    private(set) var showingFullText = false
    private var requiresFullText = false
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
    private var motion = LyricsMotionEnvelope()
    private var lastPlaying: Bool?
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
        fullText.isEditable = false; fullText.isSelectable = true
        fullText.drawsBackground = false; fullText.textColor = .white
        fullText.font = .systemFont(ofSize: 16, weight: .medium)
        fullText.textContainerInset = NSSize(width: 0, height: 6)
        fullText.isVerticallyResizable = true; fullText.isHorizontallyResizable = false
        fullText.autoresizingMask = [.width]
        fullText.textContainer?.widthTracksTextView = true
        fullTextScroll.documentView = fullText
        fullTextScroll.drawsBackground = false; fullTextScroll.hasVerticalScroller = true
        fullTextScroll.autohidesScrollers = true; fullTextScroll.isHidden = true
        addSubview(fullTextScroll)
        for button in [readingButton, reloadButton] {
            button.isBordered = false; button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = NSColor(white: 1, alpha: 0.65)
            button.target = self; addSubview(button)
        }
        readingButton.action = #selector(toggleReading)
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "가사 다시 불러오기")
        reloadButton.toolTip = "가사 다시 불러오기"
        reloadButton.setAccessibilityLabel("가사 다시 불러오기")
        reloadButton.action = #selector(reloadLyrics)
        readingButton.isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.group)
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
        readingButton.frame = NSRect(x: 18, y: 0, width: 76, height: 22)
        reloadButton.frame = NSRect(x: 98, y: 0, width: 22, height: 22)
        fullTextScroll.frame = NSRect(x: 18, y: 24, width: max(0, bounds.width - 36), height: max(0, bounds.height - 28))
        fullText.frame.size.width = fullTextScroll.contentSize.width
        fullText.textContainer?.containerSize = NSSize(width: fullTextScroll.contentSize.width, height: .greatestFiniteMagnitude)
        if let container = fullText.textContainer, let manager = fullText.layoutManager {
            manager.ensureLayout(for: container)
            fullText.frame.size.height = max(fullTextScroll.contentSize.height, manager.usedRect(for: container).height + 12)
        }
        positionRows()
    }
    @objc func toggleReading() {
        guard !requiresFullText else { return }
        showingFullText.toggle(); applyReadingMode()
    }
    @objc private func reloadLyrics() { onReload?() }
    private func applyReadingMode() {
        fullTextScroll.isHidden = !showingFullText
        for row in rows.values { row.isHidden = showingFullText }
        readingButton.title = requiresFullText ? "가사 전문" : (showingFullText ? "실시간 보기" : "전문 보기")
        readingButton.isEnabled = !requiresFullText
        readingButton.setAccessibilityLabel(readingButton.title)
        if showingFullText { title.isHidden = true; detail.isHidden = true }
    }
    /// `version` (LyricsController.version) replaces the deep comparison of a whole document. `advance: false` leaves the
    /// per-frame motion to the display loop and only applies a changed state.
    func update(_ state: LyricsState, version: Int? = nil, time: TimeInterval, duration: Double? = nil, playing: Bool = true,
                frameTime: Double = hardwareSeconds(), advance: Bool = true) {
        let changed = self.duration != duration || (version.map { $0 != stateVersion } ?? (self.state != state))
        if changed {
            self.state = state; self.duration = duration; stateVersion = version
            lastPosition = nil; settled = false; lastPlaying = nil; motion = LyricsMotionEnvelope()
            rows.values.forEach { $0.removeFromSuperview() }; rows.removeAll()
            document = nil; timeline = nil; lastTime = nil; lastFrameTime = nil; accessibilityIndex = nil
            let previousText = fullText.string
            let wasReading = showingFullText
            fullText.string = ""; requiresFullText = false; showingFullText = false
            readingButton.isHidden = true
            title.isHidden = false; detail.isHidden = false
            switch state {
            case .idle, .loading:
                title.stringValue = "가사를 불러오는 중…"; detail.stringValue = "Apple Music"
            case .missing:
                title.stringValue = "음악 앱에서 가사를 열어 주세요"; detail.stringValue = "가사가 준비되면 자동으로 표시합니다"
            case .failed:
                title.stringValue = "가사 캐시를 읽을 수 없습니다"; detail.stringValue = "잠시 후 다시 확인합니다"
            case .document(let document):
                fullText.string = document.plainText
                if previousText != fullText.string { fullText.scrollToBeginningOfDocument(nil) }
                requiresFullText = document.lines.isEmpty || document.hasUntimedLines
                showingFullText = requiresFullText || (wasReading && previousText == fullText.string)
                readingButton.isHidden = false
                if requiresFullText {
                    title.stringValue = ""; detail.stringValue = ""
                } else {
                    self.document = document; timeline = LyricsTimeline(document: document, duration: duration)
                    title.isHidden = true; detail.isHidden = true
                }
            }
            applyReadingMode()
            needsLayout = true
            if showingFullText { setAccessibilityLabel("가사 전문") }
            else if document == nil { setAccessibilityLabel(title.stringValue + ". " + detail.stringValue) }
        }
        if changed || advance { self.advance(to: time, frameTime: frameTime, playing: playing) }
    }
    /// The display loop only needs to call `advance` while the song moves or the list is still scrolling.
    func needsAdvance(at time: TimeInterval, playing: Bool = true) -> Bool { !showingFullText && document != nil && (!settled || lastTime != time || lastPlaying != playing) }
    func advance(to time: TimeInterval, frameTime: Double = hardwareSeconds(), playing: Bool = true) {
        guard let document, let timeline, !timeline.slots.isEmpty else { return }
        let target = timeline.position(at: time)
        let playbackDelta = time - (lastTime ?? time)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let resetMotion = lastFrameTime == nil || playbackDelta < -0.1 || playbackDelta > 1
        if resetMotion || reduceMotion { scroll.reset(to: target) }
        else { scroll.advance(toward: target, deltaTime: frameTime - (lastFrameTime ?? frameTime)) }
        motion.advance(playing: playing, frameTime: frameTime, reset: resetMotion, reduceMotion: reduceMotion)
        lastPlaying = playing
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
            row.wantsLayer = true; row.isHidden = showingFullText; addSubview(row, positioned: .below, relativeTo: readingButton); rows[index] = row
        }
        for (index, row) in rows {
            if let row = row as? LyricRowView { row.advance(to: time, emphasis: max(0, 1 - abs(Double(index) - position)),
                          motionGain: motion.gain, playing: playing, frameTime: frameTime, resetMotion: resetMotion) }
            if let row = row as? LyricsWaitView, let end = timeline.slots[index].end {
                row.advance(to: time, start: timeline.slots[index].start, end: end)
            }
        }
        if rows.count > needed.count {
            for index in rows.keys.filter({ !needed.contains($0) }) { rows[index]?.removeFromSuperview(); rows.removeValue(forKey: index) }
        }
        settled = position == target && motion.settled && rows.values.compactMap { $0 as? LyricRowView }.allSatisfy(\.pageSettled)
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
            let frame = NSRect(x: 18, y: (bounds.height + 24) / 2 + CGFloat(Double(index) - position) * rowSpacing - 22 + creditInset,
                               width: max(0, bounds.width - 36), height: 44)
            if let lyric = row as? LyricRowView { lyric.topOcclusion = max(0, 24 - frame.minY) }
            if row.frame != frame { row.frame = frame }
            let alpha = 1 - 0.55 * min(1, CGFloat(abs(Double(index) - position)))
            if row.alphaValue != alpha { row.alphaValue = alpha }
        }
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, !isHidden, alphaValue > 0.3 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for control in [readingButton, reloadButton] where !control.isHidden && control.frame.contains(local) { return control }
        if showingFullText, fullTextScroll.frame.contains(local) { return super.hitTest(point) }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Presses travel on to the island, so holding the lyrics can toggle them back (a plain tap on them does nothing).
    override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
    override func scrollWheel(with event: NSEvent) {
        if showingFullText { fullTextScroll.scrollWheel(with: event) }
    }
}
