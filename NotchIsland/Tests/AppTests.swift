// App globals from main.swift are prepended by run.sh; no application lifecycle is started.
let testApplication = NSApplication.shared

func makeTestApp() -> App {
    let app = App()
    app.panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    app.view = IslandView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    app.panel.contentView = app.view
    app.mainP = Piece(panel: app.panel)
    app.makeSlotItems()
    app.simLux = 1000
    // Keep step() from querying real hardware or launching background helpers.
    let later = CFAbsoluteTimeGetCurrent() + 3600
    app.tAppearance = later; app.tFiles = later; app.tVolume = later
    app.tBattery = later; app.tMusic = later; app.tAirPods = later
    return app
}
func track(_ title: String = "Track", artist: String = "Artist", bundle: String = "test.player") -> Media {
    Media(title: title, artist: artist, playing: true, duration: 120, elapsed: 0,
          readAt: Date(), storeID: "", bundleID: bundle)
}
func isAnimating(_ eq: EqView) -> Bool {
    Mirror(reflecting: eq).children.first { $0.label == "animating" }?.value as? Bool ?? false
}
func bannerTitle(_ app: App) -> String? {
    if case .battery(let title, _, _)? = app.banner { return title }
    return nil
}

// Removing an active media item must release both the expanded and compact audio users.
let audioApp = makeTestApp()
audioApp.media = track()
audioApp.shape = .expanded
audioApp.syncActivities()
audioApp.populate(audioApp.c, bn: nil, kind: .media)
let compactEq = audioApp.slotItems[.media]!.detail as! EqView
audioApp.usedViews = [compactEq]
audioApp.refreshSlots()
assert(isAnimating(audioApp.c.bodyEq) && isAnimating(compactEq))
audioApp.media = nil
audioApp.populate(audioApp.c, bn: nil, kind: nil)
audioApp.refreshSlots()
assert(!isAnimating(audioApp.c.bodyEq) && !isAnimating(compactEq))

// A track change cancels the delayed scroll seek, but ordinary position updates do not.
let seekApp = makeTestApp()
seekApp.media = track()
seekApp.shape = .expanded
seekApp.scrubBy(0.2, seekApp.media!)
var sameTrack = seekApp.media!
sameTrack.elapsed = 10
seekApp.media = sameTrack
assert(seekApp.seekFraction != nil && seekApp.seekTimer?.isValid == true)
let nextTrack = track(artist: "Different artist") // Same title must not defeat the identity check.
seekApp.artCache[seekApp.artworkKey(nextTrack)] = (NSImage(size: NSSize(width: 1, height: 1)), accent)
seekApp.seekHoldUntil = Date().addingTimeInterval(10)
seekApp.applyPolled(.media(nextTrack))
assert(seekApp.media?.trackID == nextTrack.trackID)
assert(seekApp.seekFraction == nil && seekApp.seekTrack == nil && seekApp.seekTimer == nil)
assert(seekApp.seekHoldUntil == .distantPast)
seekApp.commitSeek() // A cancelled seek must send no command or mutate the next track.
assert(seekApp.media?.elapsed == 0)

// Mouse moves and mouse-up from the old gesture cannot start a seek on the new track.
seekApp.media = track()
seekApp.scrubbed(0.4, final: false)
seekApp.media = nextTrack
seekApp.scrubbed(0.6, final: false)
seekApp.scrubbed(0.8, final: true)
assert(seekApp.seekFraction == nil && seekApp.scrubbingTrack == nil && seekApp.media?.elapsed == 0)
seekApp.scrubbed(0.3, final: false) // A fresh gesture on the new track still works.
assert(seekApp.seekFraction == 0.3 && seekApp.seekTrack == nextTrack.trackID)
seekApp.media = nil
seekApp.scrubbed(0.5, final: true)
assert(seekApp.seekFraction == nil && seekApp.seekTrack == nil)
seekApp.populate(seekApp.c, bn: nil, kind: nil)
seekApp.refreshSlots()

// A transient warning interrupts a completed timer, then returns to that timer on expiry.
let timerApp = makeTestApp()
timerApp.timer.startCountdown(minutes: 1)
timerApp.timer.target = 0
timerApp.timer.toggle()
timerApp.selected = .timer
timerApp.pinned = true
timerApp.syncActivities()
timerApp.showBanner(.battery(title: "배터리 부족", level: 10, color: bannerRed), autoHide: 3, feedback: false)
assert(timerApp.body == .banner)
timerApp.bannerHideAt = Date().addingTimeInterval(-1)
timerApp.step()
assert(timerApp.banner == nil && timerApp.body == .timer && timerApp.timer.finished && timerApp.pinned)

// Connection flags can arrive late; correct the title without extending the notification.
let batteryApp = makeTestApp()
batteryApp.applyBattery(Battery(level: 60, plugged: false, charging: false))
assert(batteryApp.banner == nil)
batteryApp.applyBattery(Battery(level: 60, plugged: true, charging: false))
assert(bannerTitle(batteryApp) == "전원 연결됨")
let expires = batteryApp.bannerHideAt
batteryApp.applyBattery(Battery(level: 60, plugged: true, charging: true))
assert(bannerTitle(batteryApp) == "충전 중" && batteryApp.bannerHideAt == expires)
batteryApp.applyBattery(Battery(level: 80, plugged: true, charging: false))
assert(bannerTitle(batteryApp) == "전원 연결됨" && batteryApp.bannerHideAt == expires)
batteryApp.applyBattery(Battery(level: 80, plugged: false, charging: false))
assert(batteryApp.banner == nil && batteryApp.bannerHideAt == nil)
batteryApp.applyBattery(Battery(level: 100, plugged: true, charging: false))
assert(bannerTitle(batteryApp) == "충전됨")
batteryApp.syncActivities()
assert(batteryApp.acts.isEmpty)
print("App audio, seek, timer banner and charging regression checks passed")

// Synthetic covers verify hue extraction, neutral artwork and colour propagation to both graphs.
func cover(_ background: NSColor, patch: NSColor? = nil) -> NSImage {
    let context = CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 48 * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
    if let patch {
        context.setFillColor(patch.cgColor)
        context.fill(CGRect(x: 16, y: 16, width: 16, height: 16))
    }
    return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 48, height: 48))
}
func rgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
    let c = color.usingColorSpace(.sRGB)!
    return (c.redComponent, c.greenComponent, c.blueComponent)
}
let blueCover = cover(.blue)
let blue = playbackColor(from: blueCover)
let (br, bg, bb) = rgb(blue)
assert(bb > 0.8 && br < 0.1 && bg < 0.1)
let (wr, wg, wb) = rgb(playbackColor(from: cover(.white, patch: .blue)))
assert(wb > 0.8 && wr < 0.1 && wg < 0.1) // Neutral margins must not wash out the accent.
let (gr, gg, gb) = rgb(playbackColor(from: cover(NSColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1))))
assert(abs(gr - gg) < 0.01 && abs(gg - gb) < 0.01 && gg >= 0.84)
let (dr, dg, db) = rgb(playbackColor(from: cover(NSColor(srgbRed: 0, green: 0.2, blue: 0, alpha: 1))))
assert(dg >= 0.84 && dr < 0.1 && db < 0.1)
assert(playbackColor(from: cover(.clear)) == accent)
let colorApp = makeTestApp()
let blueTrack = track("Blue cover")
colorApp.artCache[colorApp.artworkKey(blueTrack)] = (blueCover, blue)
colorApp.media = blueTrack
colorApp.shape = .expanded
colorApp.syncActivities()
colorApp.loadArtwork(for: blueTrack)
colorApp.populate(colorApp.c, bn: nil, kind: .media)
colorApp.refreshSlots()
let colorEq = colorApp.slotItems[.media]!.detail as! EqView
assert(colorApp.c.bodyEq.color == blue && colorEq.color == blue)
let greenCover = cover(.green)
let green = playbackColor(from: greenCover)
let greenTrack = track("Green cover")
colorApp.artCache[colorApp.artworkKey(greenTrack)] = (greenCover, green)
colorApp.media = greenTrack
colorApp.loadArtwork(for: greenTrack)
colorApp.populate(colorApp.c, bn: nil, kind: .media)
colorApp.refreshSlots()
assert(colorApp.c.bodyEq.color == green && colorEq.color == green)
colorApp.media = nil
colorApp.populate(colorApp.c, bn: nil, kind: nil)
colorApp.refreshSlots()
print("Artwork colour extraction and both playback graph colour checks passed")

// The lyrics panel grows to the right without shifting the music card or its controls.
let lyricsApp = makeTestApp()
var lyricMedia = track("가사 미리보기", artist: "NotchIsland", bundle: "com.apple.Music")
lyricMedia.elapsed = 6
lyricsApp.media = lyricMedia
lyricsApp.pinned = true; lyricsApp.locked = true
lyricsApp.selected = .media; lyricsApp.shape = .expanded
lyricsApp.syncActivities()
func timedLyricLine(start: Double, end: Double, text: String) -> LyricsLine {
    let tokens = text.split(separator: " ").map(String.init)
    let string = text as NSString
    var offset = 0
    let words = tokens.enumerated().map { index, token -> LyricsWord in
        let range = string.range(of: token, range: NSRange(location: offset, length: string.length - offset))
        offset = NSMaxRange(range)
        let duration = (end - start) / Double(tokens.count)
        return LyricsWord(start: start + Double(index) * duration, end: start + Double(index + 1) * duration, range: range)
    }
    return LyricsLine(start: start, end: end, text: text, words: words)
}
let lyricDocument = LyricsDocument(lines: [
    LyricsLine(start: 1, end: 5, text: "이전 가사가 여기에 표시됩니다"),
    timedLyricLine(start: 5, end: 9, text: "지금 재생 중인 가사를 함께 읽어요"),
    LyricsLine(start: 9, end: 13, text: "다음 가사를 기다려요")
], plainText: "Synthetic test lyrics")
lyricsApp.lyrics.accept(.document(lyricDocument), for: lyricsApp.lyricsTrack!, request: lyricsApp.lyrics.requestID)
lyricsApp.artwork = blueCover; lyricsApp.artColor = blue
func layoutLyricsApp() {
    let frame = lyricsApp.frame(for: .expanded)
    lyricsApp.panel.setFrame(frame, display: false)
    lyricsApp.view.frame = NSRect(origin: .zero, size: frame.size)
    lyricsApp.view.needsLayout = true
    lyricsApp.view.layoutSubtreeIfNeeded()
    lyricsApp.c.needsLayout = true
    lyricsApp.c.layoutSubtreeIfNeeded()
}
lyricsApp.refreshUI(); layoutLyricsApp()
let closedFrame = lyricsApp.frame(for: .expanded)
let closedArtwork = lyricsApp.c.art.frame
let closedProgress = lyricsApp.c.progress.frame
lyricsApp.lyricsTapped(); layoutLyricsApp()
let openFrame = lyricsApp.frame(for: .expanded)
assert(openFrame == closedFrame)                         // the island never changes size: the lyrics replace the card's content
assert(lyricsApp.lyricsVisible && lyricsApp.locked && lyricsApp.c.lyricsB.image != nil)
assert(lyricsApp.c.lyricsPane.frame.maxX == lyricsApp.c.mediaCardWidth!)
assert(lyricsApp.c.lyricsPane.frame.minX > lyricsApp.c.art.frame.maxX) // the existing artwork column stays beside the lyrics
assert(lyricsApp.c.lyricsB.frame.width == 24 && lyricsApp.c.lyricsB.frame.maxX <= lyricsApp.c.mediaCardWidth!)
let rows = lyricsApp.c.lyricsPane.subviews.compactMap { $0 as? LyricRowView }.sorted { $0.lineIndex < $1.lineIndex }
assert(rows.count == 3)
assert(abs((rows[1].frame.midY - rows[0].frame.midY) - (rows[2].frame.midY - rows[1].frame.midY)) < 0.001)
assert(rows[1].wordProgress.contains(where: { $0 > 0 && $0 < 1 }))
lyricsApp.c.lyricsPane.advance(to: 7)
let heldPosition = lyricsApp.c.lyricsPane.position
lyricsApp.c.lyricsPane.advance(to: 7)
assert(heldPosition == lyricsApp.c.lyricsPane.position) // Paused timing does not drift.
lyricsApp.c.lyricsPane.advance(to: 6)
layoutLyricsApp()
let lyricPoint = lyricsApp.c.convert(NSPoint(x: lyricsApp.c.lyricsPane.frame.midX, y: lyricsApp.c.lyricsPane.frame.midY), to: lyricsApp.view.superview!)
assert(lyricsApp.view.hitTest(lyricPoint) === lyricsApp.c.lyricsPane)
let toggleCenter = NSPoint(x: lyricsApp.c.lyricsB.frame.midX, y: lyricsApp.c.lyricsB.frame.midY)
assert(lyricsApp.view.hitTest(lyricsApp.c.convert(toggleCenter, to: lyricsApp.view.superview!)) === lyricsApp.c.lyricsB)   // still toggles back
let readerButtonPoint = NSPoint(x: lyricsApp.c.lyricsPane.readingButton.frame.midX, y: lyricsApp.c.lyricsPane.readingButton.frame.midY)
let readerButtonInIsland = lyricsApp.c.lyricsPane.convert(readerButtonPoint, to: lyricsApp.view.superview!)
assert(lyricsApp.view.hitTest(readerButtonInIsland) === lyricsApp.c.lyricsPane.readingButton)
lyricsApp.c.lyricsPane.readingButton.performClick(nil)
let readerBodyInIsland = lyricsApp.c.lyricsPane.convert(NSPoint(x: lyricsApp.c.lyricsPane.bounds.midX, y: 50), to: lyricsApp.view.superview!)
assert(lyricsApp.view.hitTest(readerBodyInIsland) is NSTextView)
lyricsApp.c.lyricsPane.readingButton.performClick(nil)
if let path = ProcessInfo.processInfo.environment["NI_LYRICS_PREVIEW_PATH"] {
    // Freeze cross-fades for an inspectable offscreen snapshot using synthetic text only.
    for element in lyricsApp.c.all { element.layer?.removeAllAnimations() }
    lyricsApp.c.art.alphaValue = 1; lyricsApp.c.titleL.alphaValue = 1; lyricsApp.c.artistL.alphaValue = 1
    lyricsApp.c.bodyEq.alphaValue = 1; lyricsApp.c.progress.alphaValue = 1
    lyricsApp.c.elapsedL.alphaValue = 1; lyricsApp.c.remainL.alphaValue = 1
    lyricsApp.c.lyricsB.alphaValue = 1
    lyricsApp.c.lyricsPane.alphaValue = 1
    lyricsApp.c.lyricsPane.layoutSubtreeIfNeeded()
    if let bitmap = lyricsApp.view.bitmapImageRepForCachingDisplay(in: lyricsApp.view.bounds) {
        lyricsApp.view.cacheDisplay(in: lyricsApp.view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
    let resting = LyricsDocument(lines: [LyricsLine(start: 0, end: 1, text: "마지막으로 부른 문장"),
                                         LyricsLine(start: 10, end: 12, text: "이어서 부를 다음 문장")],
                                  plainText: "Synthetic preview", songwriters: ["테스트 작사가"])
    for (suffix, time) in [("waiting", 5.5), ("credits", 14.0)] {
        lyricsApp.c.lyricsPane.update(.document(resting), time: time, duration: 120)
        lyricsApp.c.lyricsPane.layoutSubtreeIfNeeded()
        if let bitmap = lyricsApp.view.bitmapImageRepForCachingDisplay(in: lyricsApp.view.bounds) {
            lyricsApp.view.cacheDisplay(in: lyricsApp.view.bounds, to: bitmap)
            let output = URL(fileURLWithPath: path).deletingPathExtension().path + "-" + suffix + ".png"
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        }
    }
    lyricsApp.c.lyricsPane.update(.document(lyricDocument), time: 6, duration: 120)
}
var followingTrack = lyricMedia; followingTrack.title = "다음 곡"
lyricsApp.media = followingTrack
assert(lyricsApp.lyricsRequested && lyricsApp.lyrics.state == .idle)
lyricsApp.showBanner(.battery(title: "충전 중", level: 50, color: bannerGreen), feedback: false)
lyricsApp.refreshUI()
assert(!lyricsApp.lyricsVisible && lyricsApp.lyricsRequested)
lyricsApp.banner = nil; lyricsApp.bannerHideAt = nil
lyricsApp.refreshUI()
assert(lyricsApp.lyricsVisible)
lyricsApp.mainP.x.jump(openFrame.minX); lyricsApp.mainP.h.jump(openFrame.height)
lyricsApp.mainP.w.jump(openFrame.width); lyricsApp.mainP.active = true; lyricsApp.mainP.visible = true
lyricsApp.lyricsTapped()
assert(!lyricsApp.lyricsRequested && lyricsApp.locked)
assert(lyricsApp.mainP.w.cur == closedFrame.width && !lyricsApp.c.lyricsVisible)
lyricsApp.media = track(bundle: "test.otherplayer")
lyricsApp.refreshUI()
assert(!lyricsApp.c.lyricsB.isEnabled && lyricsApp.lyricsTrack == nil)
lyricsApp.media = nil
lyricsApp.refreshUI()
print("Lyrics expansion, controls, hit testing, transient banners and player switching checks passed")

// No-gap line changes keep moving through repeated layout passes, with a hard speed ceiling.
let continuousPanel = LyricsPanelView(frame: NSRect(x: 0, y: 0, width: 300, height: 112))
let continuousLyrics = LyricsDocument(lines: [LyricsLine(start: 0, end: 1, text: "First"), LyricsLine(start: 1, end: 2, text: "Second")], plainText: "First Second")
continuousPanel.update(.document(continuousLyrics), time: 0.9, frameTime: 100)
continuousPanel.advance(to: 1.01, frameTime: 100.01)
let firstStep = continuousPanel.position
assert(firstStep > 0 && firstStep < 1)
continuousPanel.layout()
continuousPanel.advance(to: 1.02, frameTime: 100.02)
assert(continuousPanel.position > firstStep && continuousPanel.position - firstStep <= 0.03 + 0.00001)
let waitingDocument = LyricsDocument(lines: [LyricsLine(start: 0, end: 1, text: "Previous"), LyricsLine(start: 10, end: 12, text: "Upcoming")], plainText: "Previous Upcoming", songwriters: ["Fixture Writer"])
continuousPanel.update(.document(waitingDocument), time: 3, frameTime: 101)
assert(continuousPanel.subviews.contains { $0 is LyricsWaitView })
let restingPosition = continuousPanel.position
continuousPanel.advance(to: 4, frameTime: 101.01)
assert(continuousPanel.position == restingPosition)
continuousPanel.advance(to: 13, frameTime: 102)
let credit = continuousPanel.subviews.compactMap { $0 as? LyricsCreditsView }.first!
assert(credit.label.stringValue == "작사: Fixture Writer")
credit.needsLayout = true; credit.layoutSubtreeIfNeeded()
assert(abs(credit.label.frame.midY - credit.bounds.midY) < 0.001)
let precedingLyric = continuousPanel.subviews.compactMap { $0 as? LyricRowView }.max { $0.lineIndex < $1.lineIndex }!
assert(credit.frame.midY - precedingLyric.frame.midY >= continuousPanel.rowSpacing + 9)

// Raster checks cover the actual drawing path, not just the scale/timing model.
func renderLift(_ time: Double) -> NSBitmapImageRep {
    let row = LyricRowView(frame: NSRect(x: 0, y: 0, width: 180, height: 44))
    row.configure(LyricsLine(start: 0, end: 1, text: "MMMM", words: [LyricsWord(start: 0, end: 1, range: NSRange(location: 0, length: 4))]), maximumLines: 1)
    row.advance(to: time, emphasis: 1)
    let frame = row.frame
    row.layoutSubtreeIfNeeded()
    let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds)!
    row.cacheDisplay(in: row.bounds, to: bitmap)
    assert(row.frame == frame)
    if let path = ProcessInfo.processInfo.environment["NI_LYRICS_PREVIEW_PATH"] {
        let output = URL(fileURLWithPath: path).deletingPathExtension().path + "-word-" + String(time) + ".png"
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
    }
    return bitmap
}
func pixelLight(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
    return Double(max(color.redComponent, color.greenComponent, color.blueComponent) * color.alphaComponent)
}
func inkBounds(_ bitmap: NSBitmapImageRep) -> NSRect {
    var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = 0, maxY = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide where pixelLight(bitmap, x, y) > 0.04 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}
let readingWord = renderLift(0.5)
let finishedWord = renderLift(1)
let unreadWord = renderLift(0)
let readingBounds = inkBounds(readingWord), finishedBounds = inkBounds(finishedWord), unreadBounds = inkBounds(unreadWord)
assert(abs(finishedBounds.width - unreadBounds.width) <= 2) // Same font size and glyph advances.
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { assert(finishedBounds.minY < unreadBounds.minY) }
var brightSide = 0.0, dimSide = 0.0, intermediatePixels = 0
for y in Int(readingBounds.minY)..<Int(readingBounds.maxY) {
    for x in Int(readingBounds.minX)..<Int(readingBounds.maxX) {
        let light = pixelLight(readingWord, x, y)
        if CGFloat(x) < readingBounds.minX + readingBounds.width / 4 { brightSide = max(brightSide, light) }
        if CGFloat(x) > readingBounds.maxX - readingBounds.width / 4 { dimSide = max(dimSide, light) }
        if light > 0.45 && light < 0.85 { intermediatePixels += 1 }
    }
}
assert(brightSide > dimSide + 0.2 && intermediatePixels > 10)
func renderRigidCharacter(_ time: Double) -> NSBitmapImageRep {
    let row = LyricRowView(frame: NSRect(x: 0, y: 0, width: 80, height: 44))
    row.configure(LyricsLine(start: 0, end: 1, text: "명", words: [LyricsWord(start: 0, end: 1, range: NSRange(location: 0, length: 1))]), maximumLines: 1)
    row.advance(to: time, emphasis: 1)
    let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds)!
    row.cacheDisplay(in: row.bounds, to: bitmap)
    return bitmap
}
// The cloud-like lift also changes with time: compare the partial reveal (rising) with a completed one at the same lift (falling).
let referenceWord = LyricsWord(start: 0, end: 1, range: NSRange(location: 0, length: 1))
let partialLift = referenceWord.lift(at: 0.5, emphasis: 1, reduceMotion: false)
var fallLow = 0.9, fallHigh = 1 + LyricsWord.maximumLiftSpan
for _ in 0..<60 {
    let mid = (fallLow + fallHigh) / 2
    if referenceWord.lift(at: mid, emphasis: 1, reduceMotion: false) > partialLift { fallLow = mid } else { fallHigh = mid }
}
let partialCharacter = renderRigidCharacter(0.5), completedCharacter = renderRigidCharacter((fallLow + fallHigh) / 2)
var shapeDifference = 0.0, shapeSamples = 0
for x in 0..<partialCharacter.pixelsWide {
    let peakA = (0..<partialCharacter.pixelsHigh).map { pixelLight(partialCharacter, x, $0) }.max() ?? 0
    let peakB = (0..<completedCharacter.pixelsHigh).map { pixelLight(completedCharacter, x, $0) }.max() ?? 0
    guard peakA > 0.05, peakB > 0.05 else { continue }
    for y in 0..<partialCharacter.pixelsHigh {
        shapeDifference += abs(pixelLight(partialCharacter, x, y) / peakA - pixelLight(completedCharacter, x, y) / peakB)
        shapeSamples += 1
    }
}
assert(shapeSamples > 0 && shapeDifference / Double(shapeSamples) < 0.035) // Gradient changes colour, never part of a character's geometry.
let staggered = LyricRowView(frame: NSRect(x: 0, y: 0, width: 180, height: 44))
staggered.configure(LyricsLine(start: 0, end: 1, text: "가나다라", words: [LyricsWord(start: 0, end: 1, range: NSRange(location: 0, length: 4))]), maximumLines: 1)
staggered.advance(to: 0.15, emphasis: 1)
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    let lifts = staggered.characterLifts
    assert(lifts[0] > 0 && lifts[1] > 0 && lifts[1] < lifts[0] && lifts[2] < lifts[1]) // followers are pulled along, fading out
}
print("Composed-character stagger, rigid glyph geometry, fixed font size and gradient checks passed")
print("Continuous scroll speed, long-rest countdown and songwriter credit checks passed")

if ProcessInfo.processInfo.environment["NI_LYRICS_INTEGRATION"] == "1" {
    let realProvider = AppleMusicLyricsProvider()
    let cacheFiles = realProvider.root.appendingPathComponent("fsCachedData")
    var checkedIDs = Set<String>()
    var cachedDocuments = 0
    var timedWords = 0
    for file in (try? FileManager.default.contentsOfDirectory(at: cacheFiles, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8 * 1024 * 1024,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = json["data"] as? [[String: Any]] else { continue }
        for song in songs {
            guard let id = song["id"] as? String, checkedIDs.insert(id).inserted,
                  let attr = song["attributes"] as? [String: Any],
                  let title = attr["name"] as? String, let artist = attr["artistName"] as? String,
                  let relationships = song["relationships"] as? [String: Any], relationships["syllable-lyrics"] != nil else { continue }
            let query = LyricsTrack(title: title, artist: artist, album: attr["albumName"] as? String ?? "",
                                    duration: Int((attr["durationInMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000, catalogID: id)
            if case .document(let doc) = realProvider.lookup(query), !doc.lines.isEmpty {
                cachedDocuments += 1; timedWords += doc.lines.reduce(0) { $0 + $1.words.count }
            }
        }
    }
    print("Real Apple Music cache integration: timed documents loaded:", cachedDocuments, "timed words/spans:", timedWords)
    assert(cachedDocuments > 0 && timedWords > 0)
    if case .media(let nowPlaying) = queryNowPlaying(), nowPlaying.bundleID == "com.apple.Music" {
        let query = LyricsTrack(title: nowPlaying.title, artist: nowPlaying.artist, album: nowPlaying.album,
                                duration: Int(nowPlaying.duration.rounded()), catalogID: nowPlaying.storeID)
        switch realProvider.lookup(query) {
        case .document(let doc): print("Current Apple Music song: cached lyrics loaded; timed lines:", doc.lines.count)
        case .missing: print("Current Apple Music song: no matching cached lyrics yet")
        default: print("Current Apple Music song: cache could not be parsed")
        }
    }
}

// Lock, dismissal, play-tap and symbol regressions.
let lockApp = makeTestApp()
lockApp.pinned = true; lockApp.locked = true
assert(!lockApp.dismissIsland() && lockApp.pinned)                 // a locked island refuses every dismiss path
lockApp.locked = false
assert(lockApp.dismissIsland() && !lockApp.pinned)
lockApp.locked = true; lockApp.pinned = false
_ = lockApp.desiredShape()
assert(!lockApp.locked)                                            // the lock never outlives the pin
lockApp.playTapGeneration = 2
lockApp.playHoldUntil = Date().addingTimeInterval(5)
lockApp.confirmPlayState(true, retry: true, generation: 1)         // a stale confirmation neither queries nor touches the hold
assert(lockApp.playHoldUntil > Date())
let baseWidth = lockApp.expandedSize().w
_ = lockApp.frame(for: .expanded)
assert(lockApp.expandedSize().w == baseWidth && baseWidth == expandedCardWidth)   // frame(for:) has no side effects
let symbolButton = makeSymbolButton("play.fill", 30, .white)
setSymbol(symbolButton, "pause.fill", 30)
let firstImage = symbolButton.image
setSymbol(symbolButton, "pause.fill", 30)
assert(symbolButton.image === firstImage && symbolButton.identifier == nil)   // cached, and the identifier stays free
symbolButton.image = NSImage(size: NSSize(width: 4, height: 4))
setSymbol(symbolButton, "pause.fill", 30)
assert(symbolButton.image !== firstImage && symbolButton.image?.size != NSSize(width: 4, height: 4))   // an outside change is restored
print("Lock, dismissal, stale play-tap and symbol cache checks passed")

// Reader mode keeps every untimed/mixed line reachable and routes input to its controls.
let readerPanel = LyricsPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 112))
let readerHost = Flip(frame: readerPanel.frame)
readerHost.addSubview(readerPanel)
let fullReaderText = (1...30).map { "가사 전문 줄 \($0)" }.joined(separator: "\n")
readerPanel.update(.document(LyricsDocument(lines: [], plainText: fullReaderText)), time: 0)
readerPanel.layoutSubtreeIfNeeded()
assert(readerPanel.showingFullText && !readerPanel.needsAdvance(at: 0))
let readerScroll = readerPanel.subviews.compactMap { $0 as? NSScrollView }.first!
let readerText = readerScroll.documentView as! NSTextView
assert(readerText.string == fullReaderText && readerText.frame.height > readerScroll.contentSize.height)
readerText.scrollToEndOfDocument(nil)
assert(readerScroll.contentView.bounds.minY > 0)
readerPanel.update(.document(continuousLyrics), time: 0)
readerPanel.layoutSubtreeIfNeeded()
assert(!readerPanel.showingFullText)
readerPanel.readingButton.performClick(nil)
assert(readerPanel.showingFullText)
readerPanel.readingButton.performClick(nil)
assert(!readerPanel.showingFullText)
let buttonPoint = NSPoint(x: readerPanel.readingButton.frame.midX, y: readerPanel.readingButton.frame.midY)
assert(readerPanel.hitTest(buttonPoint) === readerPanel.readingButton)
var reloadCount = 0
readerPanel.onReload = { reloadCount += 1 }
readerPanel.reloadButton.performClick(nil)
assert(reloadCount == 1)
readerPanel.update(.document(LyricsDocument(lines: continuousLyrics.lines, plainText: fullReaderText, hasUntimedLines: true)), time: 0)
assert(readerPanel.showingFullText)
readerPanel.readingButton.performClick(nil)
assert(readerPanel.showingFullText)

// Every wrapped page is retained, including the final characters, and seeks can go backwards.
let pagedRow = LyricRowView(frame: NSRect(x: 0, y: 0, width: 100, height: 44))
let pagedText = "긴 가사가 여러 줄로 이어져도 마지막 문장까지 모두 볼 수 있어야 합니다"
pagedRow.configure(timedLyricLine(start: 0, end: 20, text: pagedText), maximumLines: 2)
func renderPagedRow(at time: Double) -> NSBitmapImageRep {
    pagedRow.advance(to: time, emphasis: 1)
    let bitmap = pagedRow.bitmapImageRepForCachingDisplay(in: pagedRow.bounds)!
    pagedRow.cacheDisplay(in: pagedRow.bounds, to: bitmap)
    return bitmap
}
let pageFirst = renderPagedRow(at: 0)
assert(pagedRow.pageOffsets.count > 1)
let finalPageStart = pagedRow.pageOffsets.last!.start
assert(pagedRow.pageOffset(at: finalPageStart, reduceMotion: false) == pagedRow.pageOffsets.last!.offset)
let pageLast = renderPagedRow(at: 20)
assert(inkBounds(pageLast).width > 1 && inkBounds(pageLast).height <= 44 * 2)
assert(pageFirst.representation(using: .png, properties: [:]) != pageLast.representation(using: .png, properties: [:]))
_ = renderPagedRow(at: 0)
assert(pagedRow.pageOffset(at: 0, reduceMotion: false) == 0)
print("Lyrics reader scrolling, reload controls and long-line paging checks passed")

if let path = ProcessInfo.processInfo.environment["NI_LYRICS_PREVIEW_PATH"] {
    func savePanel(_ panel: NSView, suffix: String) {
        panel.layoutSubtreeIfNeeded()
        let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds)!
        panel.cacheDisplay(in: panel.bounds, to: bitmap)
        let output = URL(fileURLWithPath: path).deletingPathExtension().path + suffix + ".png"
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
    }
    savePanel(readerPanel, suffix: "-reader")
    readerPanel.update(.document(continuousLyrics), time: 1.2)
    savePanel(readerPanel, suffix: "-panel")
    savePanel(pagedRow, suffix: "-long-first")
    pagedRow.advance(to: 20, emphasis: 1)
    savePanel(pagedRow, suffix: "-long-last")
}

// Frozen playback must hold highlighting, release lift/swell, finish scrolling and stop requesting frames.
let pausePanel = LyricsPanelView(frame: NSRect(x: 0, y: 0, width: 300, height: 112))
let pauseDocument = LyricsDocument(lines: [timedLyricLine(start: 0, end: 4, text: "가 나 다 라"),
                                         timedLyricLine(start: 4, end: 8, text: "마 바 사 아")], plainText: "Pause fixture")
pausePanel.update(.document(pauseDocument), time: 0.8, frameTime: 100)
let pauseRow = pausePanel.subviews.compactMap { $0 as? LyricRowView }.first { $0.lineIndex == 0 }!
let frozenProgress = pauseRow.wordProgress
let initialLift = pauseRow.characterLifts.reduce(0, +)
let initialScale = pauseRow.characterScales.max()!
assert(initialLift > 0 && initialScale > 1)
assert(pausePanel.needsAdvance(at: 0.8, playing: false))
pausePanel.advance(to: 0.8, frameTime: 100.01, playing: false)
let pauseStartLift = pauseRow.characterLifts.reduce(0, +)
assert(abs(pauseStartLift - initialLift) < 0.00001)
for frame in 1...30 {
    pausePanel.advance(to: 0.8, frameTime: 100.01 + Double(frame) / 60, playing: false)
    assert(pauseRow.wordProgress == frozenProgress)
}
assert(pauseRow.characterLifts.reduce(0, +) < initialLift)
assert(pauseRow.characterScales.max()! < initialScale)
for frame in 31...180 { pausePanel.advance(to: 0.8, frameTime: 100.01 + Double(frame) / 60, playing: false) }
assert(pauseRow.characterLifts.allSatisfy { $0 == 0 })
assert(pauseRow.characterScales.allSatisfy { $0 == 1 })
assert(pausePanel.settled && !pausePanel.needsAdvance(at: 0.8, playing: false))
pausePanel.advance(to: 0.8, frameTime: 104, playing: true)
assert(pauseRow.characterLifts.allSatisfy { $0 == 0 })
pausePanel.advance(to: 0.85, frameTime: 104.1, playing: true)
assert(pauseRow.characterLifts.contains { $0 > 0 })
assert(pauseRow.wordProgress != frozenProgress)
// A line change interrupted by pause must still finish its presentation scroll.
pausePanel.advance(to: 3.99, frameTime: 105, playing: true)
pausePanel.advance(to: 4.01, frameTime: 105.01, playing: true)
let interruptedPosition = pausePanel.position
pausePanel.advance(to: 4.01, frameTime: 105.02, playing: false)
for frame in 1...240 { pausePanel.advance(to: 4.01, frameTime: 105.02 + Double(frame) / 60, playing: false) }
assert(pausePanel.position > interruptedPosition && pausePanel.position == 1 && pausePanel.settled)
// Backward seeks reset stale paused motion, and paused-open panels start at rest.
pausePanel.advance(to: 0.5, frameTime: 110, playing: false)
assert(pausePanel.position == 0 && pausePanel.settled)
let pausedOpen = LyricsPanelView(frame: pausePanel.frame)
pausedOpen.update(.document(pauseDocument), time: 0.8, playing: false, frameTime: 200)
assert(pausedOpen.subviews.compactMap { $0 as? LyricRowView }.allSatisfy { $0.characterLifts.allSatisfy { $0 == 0 } })
print("Paused lyrics release, frozen highlights, gentle resume and finite scroll settling checks passed")

// Finish a partially turned long-line page during pause, and do not rewind it on resume.
let pagePauseRow = LyricRowView(frame: NSRect(x: 0, y: 0, width: 100, height: 44))
pagePauseRow.configure(timedLyricLine(start: 0, end: 20, text: pagedText), maximumLines: 2)
pagePauseRow.advance(to: 0, emphasis: 1, frameTime: 300)
let nextPage = pagePauseRow.pageOffsets[1]
let pagePauseTime = nextPage.start - 0.1
pagePauseRow.advance(to: pagePauseTime, emphasis: 1, frameTime: 301, resetMotion: true)
let partialPage = pagePauseRow.displayedPageOffset
assert(partialPage > 0 && partialPage < Double(nextPage.offset))
pagePauseRow.advance(to: pagePauseTime, emphasis: 1, playing: false, frameTime: 301.01)
for frame in 1...240 { pagePauseRow.advance(to: pagePauseTime, emphasis: 1, playing: false, frameTime: 301.01 + Double(frame) / 60) }
assert(pagePauseRow.pageSettled && pagePauseRow.displayedPageOffset == Double(nextPage.offset))
pagePauseRow.advance(to: pagePauseTime, emphasis: 1, playing: true, frameTime: 306)
pagePauseRow.advance(to: pagePauseTime + 0.05, emphasis: 1, playing: true, frameTime: 306.05)
assert(pagePauseRow.displayedPageOffset == Double(nextPage.offset))
pagePauseRow.advance(to: 0, emphasis: 1, playing: false, frameTime: 307, resetMotion: true)
assert(pagePauseRow.displayedPageOffset == 0)
print("Paused long-line page completion and forward-only resume checks passed")
