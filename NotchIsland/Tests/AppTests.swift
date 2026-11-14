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
