import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - App

struct LockBorderGeometry: Equatable {
    var strip: NSRect
    var island: NSRect
    var earLeft: Bool
    var earRight: Bool
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Shape { case collapsed, activity, peek, pressed, expanded }

    // press / long-press state
    var pressing = false                 // finger down on a closed island, long-press not yet fired
    var pressedWhileExpanded = false
    var longPressTimer: Timer?

    // spring-driven window size (smooth, interruptible, velocity-preserving)
    var link: CADisplayLink?
    var mainP: Piece!
    var rowView: ActivityRowView { c.activityRow }
    var stiffness: CGFloat = 400, damping: CGFloat = 30     // the island's own spring (changes with the shape)
    var signalSources: [DispatchSourceSignal] = []
    var simLux: Double?
    var atRest = true                      // spring has settled
    var popUntil = Date.distantPast       // brief swell-and-return when there is nothing to show

    var panel: NSPanel!
    var view: IslandView!
    var c: Content { view.content }
    static func pickScreen() -> NSScreen { NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0] }
    var screen: NSScreen = App.pickScreen()
    let timer = TimerModel()
    var shape: Shape = .collapsed

    // inputs
    var pinned = false
    var lockIsland = NSRect.zero
    var expandedSwell: CGFloat = 0       // the open island swells a little when the pointer is on it (more while pressed), and snaps back when it pins
    /// Resting width of the open island and the extra room for the lyrics pane; the swell scales only the first.
    var expandedBase: (w: CGFloat, ext: CGFloat) {
        (expandedSize().w, body == .media && lyricsRequested && supportsLyrics ? lyricsExtensionWidth : 0)
    }
    var swellSuppressed = false          // after pinning: stay small until the pointer has left
    var lockBorder: NSPanel?; var lockBorderLayer: CAShapeLayer?; var lockBorderTarget: CGFloat = 0
    var lockBorderGeometry: LockBorderGeometry?
    var playTapGeneration = 0           // bumped by every play / pause tap: delayed confirmations of an older tap are ignored
    var locked = false                 // pinned by tapping the expanded island: ignores outside clicks / Esc / sensor until tapped again
    var hoverUntil = Date.distantPast
    var lux = -1.0
    var media: Media? {
        didSet {
            if oldValue?.trackID != media?.trackID { cancelPendingSeek() }
            lyrics.select(lyricsTrack)
            if !supportsLyrics { lyricsRequested = false }
        }
    }
    var lyrics = LyricsController()
    var lyricsWidthTransition: LyricsWidthTransition?
    var lyricsRequested = false {
        didSet { if oldValue && !lyricsRequested { lyrics.suspend() } }
    }
    var supportsLyrics: Bool { media?.bundleID == "com.apple.Music" }
    var lyricsTrack: LyricsTrack? {
        guard supportsLyrics, let m = media else { return nil }
        return LyricsTrack(title: m.title, artist: m.artist, album: m.album,
                           duration: Int(max(0, m.duration).rounded()), catalogID: m.storeID)
    }
    var lyricsPlaybackTime: TimeInterval { media?.lyricsPosition(seekFraction: seekFraction) ?? 0 }
    var lyricsVisible: Bool { lyricsRequested && supportsLyrics && shape == .expanded && body == .media }
    var lyricsExtensionWidth: CGFloat { min(300, max(0, screen.frame.maxX - lyricsEdgeMargin - (screen.frame.midX + expandedCardWidth / 2))) }

    var lastPlayingAt = Date.distantPast
    var artwork: NSImage?
    var artColor: NSColor = accent
    var artworkFor = ""
    var artCache: [String: (NSImage, NSColor)] = [:]
    var battery: Battery?
    var batteryNotifications = BatteryNotifications()
    var banner: BannerKind?
    // live activities, oldest first; at most 5 are shown (the oldest are dropped first)
    var actOrder: [ActKind] = []
    var selected: ActKind?                     // which activity the expanded card shows
    var pressKind: ActKind?
    var airList: [AirPodsInfo] = []
    var bannerHideAt: Date?
    // the pocket: every file dropped on the notch is an activity of its own (paths only, nothing is copied)
    var clearedFiles: [URL] = []
    var files: [URL] = []
    var fileShown: URL?
    var fileInfo: [URL: String] = [:]
    var dragEntered = false, dragNear = false, dragActive = false, wasBtn = false, downChange = 0
    var dropping: Bool { dragEntered || dragNear }        // a file drag is over / close to the island
    var slotItems: [ActKind: SlotItem] = [:]
    var lastPlan: Plan?
    var usedViews: [NSView] = []
    // volume / brightness HUD (transient: it goes away by itself, unlike alerts)
    var hudKind: LevelKind = .volume
    var hudValue: Float = 0
    var hudMuted = false
    var hudUntil = Date.distantPast
    var lastVol: Float?, lastMute: Bool?
    let keyTap = MediaKeyTap()
    let islandShortcut = IslandShortcut()
    var keyboardReturnApp: NSRunningApplication?
    var brightTarget: Float?
    var brightCur: Float = 0
    var brightTimer: Timer?
    var keyTapTimer: Timer?
    var statusItem: NSStatusItem?
    var bannerSymbol = ""
    var airBusy = false
    var mediaBaseline = false            // first poll only records what was already playing
    var prevTimerStarted = false
    let airMonitor = AirPodsMonitor()
    var airConnections = AirPodsConnections()
    var airRefreshWork: DispatchWorkItem?
    var airRefreshPending = false
    var airFailures = 0
    var lastAudibleVolume: Float = 0.5
    var alertText: String?
    var alertUntil = Date.distantPast
    var tick = 0
    var musicBusy = false
    var ambient = -1.0               // slow average of the light while uncovered: the touch threshold follows it
    var nothingPolls = 0             // consecutive 'nothing is playing' answers
    var idleRefreshed = false
    var darkLatched = false          // dark state with hysteresis: set below threshold, cleared above 1.2x
    var sensorMisses = 0

    var notchW: CGFloat {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return screen.frame.width - l.width - r.width
        }
        return 180
    }
    var notchH: CGFloat { max(screen.safeAreaInsets.top, 32) }

    // MARK: activities

    var chargeLevel: Int { demoActsN != nil ? 55 : (battery?.level ?? 0) }
    var lowLevel: Int { demoActsN != nil ? 12 : (battery?.level ?? 0) }
    var airInfo: AirPodsInfo? { demoActsN != nil ? AirPodsInfo(name: "demo", symbol: "airpodspro", level: 80) : airList.first }

    func isActive(_ k: ActKind) -> Bool {
        switch k {
        case .media: return media != nil
        case .timer: return timer.started
        case .charging, .lowBattery: return demoActsN != nil && demoKinds.contains(k) // preview only; real battery events use transient banners
        case .airpods:    return demoActsN != nil && demoKinds.contains(k)       // real AirPods only show a banner when they connect
        case .file(let u): return files.contains(u)
        }
    }

    /// Keeps `actOrder` = the running activities in the order they started.
    func syncActivities() {
        for k in allKinds {
            let on = isActive(k), has = actOrder.contains(k)
            if on && !has { actOrder.append(k) } else if !on && has { actOrder.removeAll { $0 == k } }
        }
        for u in files where !actOrder.contains(.file(u)) { actOrder.append(.file(u)) }
        func gone(_ k: ActKind) -> Bool { if case .file(let u) = k { return !files.contains(u) }; return false }
        actOrder.removeAll(where: gone)

    }
    var acts: [ActKind] {
        var visible = Array(actOrder.suffix(5))
        if let selected, actOrder.contains(selected), !visible.contains(selected), !visible.isEmpty { visible[0] = selected }
        return visible
    }

    func bodyFor(_ k: ActKind) -> Body {
        switch k {
        case .media: return .media
        case .timer: return .timer
        case .charging, .lowBattery, .airpods: return .banner
        case .file: return .file
        }
    }

    /// The dial is shown along the bottom of an open activity card when there is more than one activity to choose from.
    var dialShown: Bool { !hudActive && !dropping && banner == nil && alertText == nil && acts.count >= 2 && cardKind != nil }
    var dialMargin: CGFloat { (shape == .expanded && dialShown) ? 62 : 0 }       // room under the island for the dial's ticks
    var dialWasOn = false
    var scrollHolding: Bool { dialShown && shape == .expanded && Date().timeIntervalSince(lastScrollAt) < 1.0 }
    var holdH: CGFloat = 0                              // while scrolling the card never gets lower, so the pointer stays on the dial
    var lastScrollAt = Date.distantPast
    var dialPos: CGFloat = 0                            // where the fingers have turned the wheel, in activities (continuous)
    var dialLastTick = 0
    var lastDialHaptic = Date.distantPast
    var dialSettle: Timer?

    /// Two fingers sideways over the dial turn the wheel: it follows the fingers (and keeps going when they flick it), every tick
    /// is a little magnet, the long ticks (the running activities) also tap the trackpad, and when it stops it settles on the
    /// nearest activity.
    func handleScroll(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }   // sideways swipes only
        let finger = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX     // fingers moving left < 0
        if hudActive {                                                       // volume / brightness HUD: sideways = the slider
            hudDragged(min(1, max(0, hudValue + Float(finger) / 400)))
            return
        }
        guard shape == .expanded else { return }
        if lyricsVisible, c.convert(e.locationInWindow, from: nil).x >= (c.mediaCardWidth ?? c.bounds.width) { return }
        guard dialShown, e.locationInWindow.y < view.bottomInset + 66 else {           // on the card itself
            if cardKind == .media, let m = media, m.duration > 0 { scrubBy(finger / 450, m) }
            return
        }
        let now = Date()
        let fresh = e.phase == .began || e.phase == .mayBegin || now.timeIntervalSince(lastScrollAt) > 0.3
        if fresh { dialPos = view.dial.position; dialLastTick = Int((dialPos * CGFloat(DialView.perMajor)).rounded()) }
        lastScrollAt = now
        holdH = max(holdH, mainP.h.cur, mainP.h.tgt)
        let unit = DialView.gap * CGFloat(DialView.perMajor)
        dialPos -= finger / (unit * 1.9)                                                       // fingers left: on to the next (and round again); a gentle ratio
        turnDial()
        dialSettle?.invalidate()
        let t = Timer(timeInterval: 0.14, repeats: false) { [weak self] _ in self?.settleDial() }   // no more events (or momentum): settle
        RunLoop.main.add(t, forMode: .common); dialSettle = t
    }

    /// Click and drag on the dial's ticks: the ticks follow the pointer one to one.
    func dialDragged(_ dx: CGFloat, _ phase: Int) {
        guard shape == .expanded, dialShown else { return }
        lastScrollAt = Date()
        switch phase {
        case 0:
            dialSettle?.invalidate()
            dialPos = view.dial.position; dialLastTick = Int((dialPos * CGFloat(DialView.perMajor)).rounded())
            holdH = max(holdH, mainP.h.cur, mainP.h.tgt)
        case 1:
            dialPos -= dx / (DialView.gap * CGFloat(DialView.perMajor))
            turnDial()
        default:
            settleDial()
        }
    }

    // MARK: seeking (progress bar drag, or sideways scrolling on the music card)
    var seekFraction: CGFloat?                  // where the user has put the playhead, until it is committed
    var seekTrack: Media.TrackID?
    var scrubbingTrack: Media.TrackID?           // keep the original drag target until mouse-up, even if the track changes
    var playHoldUntil = Date.distantPast        // right after a play / pause tap the poll may still report the old state
    var seekHoldUntil = Date.distantPast        // right after a seek the poll still reports the old position: ignore it
    var seekTimer: Timer?

    func cancelPendingSeek() {
        seekTimer?.invalidate(); seekTimer = nil
        seekFraction = nil; seekTrack = nil
        seekHoldUntil = .distantPast
    }

    func scrubBy(_ d: CGFloat, _ m: Media) {
        guard m.duration > 0, m.trackID == media?.trackID else { return }
        seekTrack = m.trackID
        let base = seekFraction ?? CGFloat(m.elapsedNow / m.duration)
        seekFraction = min(1, max(0, base + d))
        refreshUI()
        seekTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in self?.commitSeek() }
        RunLoop.main.add(t, forMode: .common); seekTimer = t
    }

    func scrubbed(_ f: CGFloat, final: Bool) {
        if !final && scrubbingTrack == nil { scrubbingTrack = media?.trackID }
        let target = scrubbingTrack ?? media?.trackID
        if final { scrubbingTrack = nil }
        guard let target, target == media?.trackID else { cancelPendingSeek(); return }
        seekTimer?.invalidate(); seekTimer = nil
        seekTrack = target
        seekFraction = f
        if final { commitSeek() } else { refreshUI() }
    }

    func commitSeek() {
        guard let f = seekFraction, let target = seekTrack, var m = media,
              target == m.trackID, m.duration > 0 else { cancelPendingSeek(); return }
        cancelPendingSeek()
        let pos = Double(f) * m.duration
        sendMediaSeek(pos)
        m.elapsed = pos; m.readAt = Date(); media = m
        seekHoldUntil = Date().addingTimeInterval(1.5)
        refreshUI()
    }

    /// Shows the wheel where the fingers have it, pulled towards the nearest tick like a detent, and follows it with the card.
    func turnDial() {
        let per = CGFloat(DialView.perMajor)
        let t = dialPos * per
        let n = t.rounded(), f = t - n
        let pulled = n + (f < 0 ? -1 : 1) * 0.5 * pow(min(2 * abs(f), 1), 2.0)       // it dwells on a tick, then slips to the next
        view.dial.set(pulled / per, animated: false)
        let tick = Int(n), perI = DialView.perMajor
        if tick != dialLastTick {
            // the little magnets on the ordinary ticks are silent; a tap on the trackpad only when the wheel catches on one of the
            // long ticks, i.e. on a running activity (also when a quick turn skips past several ticks in one go)
            let lo = min(tick, dialLastTick), hi = max(tick, dialLastTick)
            let caught = (lo...hi).contains { $0 % perI == 0 && $0 != dialLastTick }
            dialLastTick = tick
            if caught, Date().timeIntervalSince(lastDialHaptic) > 0.03 {
                lastDialHaptic = Date()
                haptic(.levelChange)
            }
        }
        let a = acts
        guard !a.isEmpty else { return }
        let idx = ((Int(dialPos.rounded()) % a.count) + a.count) % a.count          // endless: past the last comes the first
        if a[idx] != cardKind { selected = a[idx] }
    }

    func settleDial() {
        guard shape == .expanded, dialShown, !acts.isEmpty else { return }
        let r = dialPos.rounded()
        let idx = ((Int(r) % acts.count) + acts.count) % acts.count
        dialPos = r
        selected = acts[idx]
        view.dial.set(r, animated: true)
    }

    var cardKind: ActKind? { if let s = selected, acts.contains(s) { return s }; return acts.first }

    func bannerFor(_ k: ActKind) -> BannerKind? {
        switch k {
        case .charging:   return .battery(title: "충전 중", level: chargeLevel, color: bannerGreen)
        case .lowBattery: return .battery(title: "배터리 부족", level: lowLevel, color: lowLevel <= 10 ? bannerRed : accent)
        case .airpods:    let d = airInfo; return .airpods(symbol: d?.symbol ?? "airpods", level: d?.level)
        default:          return nil
        }
    }
    /// What the banner body shows: a one-off banner, or the selected charging / AirPods activity.
    var displayBanner: BannerKind? {
        if let b = banner { return b }
        guard !hudActive, alertText == nil, let k = cardKind else { return nil }
        return bannerFor(k)
    }

    var body: Body {
        if hudActive { return .hud }
        if dropping { return .drop }
        if banner != nil { return .banner }
        if timer.finished, cardKind == .timer { return .timer }
        if alertText != nil { return .alert }
        switch cardKind {
        case .media?: return .media
        case .timer?: return .timer
        case .file(_)?: return .file
        case .charging?, .lowBattery?, .airpods?: return .banner
        case nil: return .none
        }
    }
    var hudActive: Bool { Date() < hudUntil }
    var liveActivity: Bool { hudActive || banner != nil || alertText != nil || !acts.isEmpty }
    let iconWing: CGFloat = 46                                       // space beside the notch for one icon
    /// Space beside the notch when a single activity shows its icon on the left and its detail on the right.
    func wingWidth(_ k: ActKind) -> CGFloat {
        switch k { case .timer: return 66; case .charging: return 58; case .lowBattery: return 62; case .airpods: return 44; default: return 50 }
    }
    /// Charging and low battery show their percentage (not an icon) in the narrow slots beside the notch.
    func showsPercent(_ k: ActKind) -> Bool { k == .charging || k == .lowBattery }
    func slotView(_ k: ActKind) -> (view: NSView, size: CGSize) {
        guard let it = slotItem(k) else { return (NSView(), .zero) }
        return showsPercent(k) ? (it.detail, it.detailSize) : (it.icon, CGSize(width: 24, height: 24))
    }
    func slotWing(_ k: ActKind) -> CGFloat { showsPercent(k) ? 58 : iconWing }     // room beside the notch for that slot
    var bannerWing: CGFloat { if case .airpods? = displayBanner { return 42 }; return 110 }       // AirPods: just the icon and the ring
    var expandedExtra: CGFloat { expandedExtraFor(body) }
    func expandedExtraFor(_ b: Body) -> CGFloat {
        switch b {
        case .media:  return 122
        case .file: return 104
        case .drop: return 62
        case .timer:  return 62
        case .banner, .hud: return 0
        default:      return 38
        }
    }

    // MARK: layout plan: which activity goes where

    struct Plan: Equatable {
        var left: ActKind?
        var right: ActKind?
        var rightDetail = false         // right slot shows the detail of the same activity (single activity)
        var row: [ActKind] = []         // additional activities inside the extended notch
    }

    func makePlan() -> Plan {
        let a = acts
        if shape == .expanded {
            // an expanded card keeps the other activities as small icons beside the notch
            // only the tall cards have room beside the notch; one-line banners (charging, AirPods...) fill the whole band
            guard !hudActive, banner == nil, alertText == nil, let ck = cardKind, body == .media || body == .timer || body == .file else { return Plan() }
            let others = a.filter { $0 != ck }
            switch others.count {
            case 0:  return Plan()
            case 1:  return Plan(left: others[0], right: others[0], rightDetail: true)
            default: return Plan(left: others[0], right: others[1])
            }
        }
        switch a.count {
        case 0:  return Plan()
        case 1:  return Plan(left: a[0], right: a[0], rightDetail: true)
        default: return Plan(left: a[0], right: a[1], row: Array(a.dropFirst(2)))
        }
    }

    // MARK: geometry (screen coordinates, y up)

    var notchLeft: CGFloat { screen.frame.midX - notchW / 2 }
    var notchRight: CGFloat { screen.frame.midX + notchW / 2 }
    /// Height of the compact island. Charging on its own stays within the menu bar (no taller than the notch).
    var compactH: CGFloat { (acts.count == 1 && acts[0] == .charging) ? notchH : notchH + 8 }

    func frame(for s: Shape) -> NSRect {
        let a = acts, n = a.count
        let mid = screen.frame.midX, top = screen.frame.maxY
        func r(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: top - h, width: w, height: h) }
        func compact(extra: CGFloat, h: CGFloat) -> NSRect {
            switch n {
            case 0: let w = notchW + extra; return r(mid - w / 2, w, h)
            case 1: let w = notchW + 2 * wingWidth(a[0]) + extra; return r(mid - w / 2, w, h)
            default:
                let wl = max(slotWing(a[0]), slotWing(a[1]))
                let w = max(notchW + 2 * wl, compactRowWidth + 36) + extra
                return r(mid - w / 2, w, h + compactRowHeight)
            }
        }
        switch s {
        case .collapsed: return r(notchLeft, notchW, notchH)
        case .activity:  return n == 0 ? r(notchLeft, notchW, notchH) : compact(extra: 0, h: compactH)
        case .peek:      return compact(extra: 24, h: n == 0 ? notchH : compactH)           // swells sideways only
        case .pressed:   return compact(extra: 44, h: n == 0 ? notchH + 6 : compactH)      // idle press: sideways AND a little down
        case .expanded:
            let (w, h) = expandedSize()
            let extensionWidth = expandedBase.ext
            let k = 1 + expandedSwell                                          // hover / press swell: the whole island scales
            return r(mid - w * k / 2, w * k + extensionWidth, h * k)
        }
    }

    /// Resting size of the open island for the current body (no swell, no lyrics extension).
    func expandedSize() -> (w: CGFloat, h: CGFloat) {
        switch body {
        case .hud:    return (284, notchH + 40)                     // dropped below the notch
        case .banner:
            if case .airpods? = displayBanner { return (expandedCardWidth, notchH + 64) }
            return (notchW + 2 * bannerWing, notchH)
        default:      return (expandedCardWidth, notchH + expandedExtra)
        }
    }

    var compactRowHeight: CGFloat { acts.count >= 3 ? 42 : 0 }
    var compactRowWidth: CGFloat {
        let items = acts.dropFirst(2).compactMap { slotItem($0) }
        guard !items.isEmpty else { return 0 }
        return 28 + items.reduce(0) { $0 + $1.pillWidth } + 16 * CGFloat(max(items.count - 1, 0))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = makePanel(frame(for: .collapsed))

        view = IslandView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.content.notchH = notchH
        view.autoresizingMask = [.width, .height]
        view.onPress = { [weak self] in self?.pressBegan() }
        view.onRelease = { [weak self] inside in self?.pressEnded(inside: inside) }
        panel.contentView = view
        panel.orderFrontRegardless()
        makeSticky(panel)
        let r0 = frame(for: .collapsed)
        mainP = Piece(panel: panel); mainP.active = true; mainP.visible = true
        mainP.x.jump(r0.minX); mainP.w.jump(r0.width); mainP.h.jump(r0.height)
        rowView.onPress = { [weak self] in self?.pressBegan() }
        rowView.onRelease = { [weak self] inside in self?.pressEnded(inside: inside) }
        wire(c.prevB, #selector(prevTapped)); wire(c.playB, #selector(playPauseTapped)); wire(c.nextB, #selector(nextTapped))
        wire(c.lyricsB, #selector(lyricsTapped))
        lyrics.onChange = { [weak self] in
            guard let self else { return }
            self.refreshUI(); self.applyShape()
        }
        wire(c.pauseB, #selector(timerToggleTapped)); wire(c.cancelB, #selector(timerCancelTapped))
        attachShadow(to: mainP) { [weak self] size in
            notchPath(size.width, size.height, earL: self?.view.earLeft ?? true, earR: self?.view.earRight ?? true)
        }
        mainP.shadow?.orderFrontRegardless(); mainP.shadow.map { makeSticky($0) }
        makeSlotItems()
        link = screen.displayLink(target: self, selector: #selector(animTick(_:)))
        link?.add(to: .main, forMode: .common)
        link?.isPaused = true

        if let t = demoAlert { showAlert(t) }
        if demoTimer { timer.toggle(); pinned = true }
        if demoCharging { showBanner(.battery(title: "충전 중", level: 55, color: bannerGreen)) }
        if demoAirpods { showBanner(.airpods(symbol: "airpodspro", level: 80), autoHide: ProcessInfo.processInfo.environment["NI_AUTOHIDE"] != nil ? 4 : nil) }
        if let n = demoActsN {                                         // --demo-acts N: N fake activities, none pinned open
            if let pick = demoPick {
                if pick.contains("media") { media = Media(title: "승리를 위하여", artist: "트랜스픽션", playing: true, duration: 208, elapsed: 29, readAt: Date(), storeID: "") }
                if pick.contains("timer") { startDemoTimer() }
                prevTimerStarted = timer.started
                for (name, k) in [("charging", ActKind.charging), ("airpods", .airpods), ("lowBattery", .lowBattery)] where pick.contains(name) { demoKinds.insert(k) }
            } else {
            if n >= 1 { media = Media(title: "승리를 위하여", artist: "트랜스픽션", playing: true, duration: 208, elapsed: 29, readAt: Date(), storeID: "") }
            if n >= 2 { startDemoTimer() }
            prevTimerStarted = timer.started                           // don't auto-open for the demo stopwatch
            for (i, k) in [ActKind.charging, .airpods, .lowBattery].enumerated() where n >= 3 + i { demoKinds.insert(k) }
            }
        }
        if demoVolume { showHUD(.volume, 0.62, muted: false, seconds: 30) }
        if demoBrightness { showHUD(.brightness, 0.78, muted: false, seconds: 30) }
        if demoMedia {
            media = Media(title: "승리를 위하여", artist: "트랜스픽션", playing: true, duration: 208, elapsed: 29, readAt: Date(), storeID: "")
            pinned = ProcessInfo.processInfo.environment["NI_NOPIN"] == nil     // NI_NOPIN=1: start collapsed (screenshots)
        }
        battery = readBattery()
        if let b = battery { _ = batteryNotifications.update(b) }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let s = self, s.pinned else { return }
            s.dismissIsland()                        // click anywhere outside the island closes it
        }
        if ProcessInfo.processInfo.environment["NI_TEST_SIGNALS"] != nil {     // test hook: simulate the sensor
            signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN); signal(SIGWINCH, SIG_IGN); signal(SIGURG, SIG_IGN)
            signal(SIGHUP, SIG_IGN)
            let stallSrc = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)     // SIGHUP = kill the audio tap silently (test hook)
            stallSrc.setEventHandler { AudioLevels.shared.debugStall() }
            stallSrc.resume(); signalSources.append(stallSrc)
            let hudSrc = DispatchSource.makeSignalSource(signal: SIGURG, queue: .main)     // SIGURG = pop a brightness HUD (test hook)
            hudSrc.setEventHandler { [weak self] in self?.showHUD(.brightness, 0.6, seconds: 1.8) }
            hudSrc.resume(); signalSources.append(hudSrc)
            let endSrc = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)   // SIGWINCH = every activity ends
            endSrc.setEventHandler { [weak self] in self?.timer.reset(); self?.media = nil; self?.alertText = nil; self?.banner = nil }
            endSrc.resume(); signalSources.append(endSrc)
            for (sig, down) in [(SIGUSR1, true), (SIGUSR2, false)] {
                let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                src.setEventHandler { [weak self] in
                    guard let s = self else { return }
                    s.simLux = down ? 1 : 1000               // goes through the normal edge detection
                }
                src.resume(); signalSources.append(src)
            }
        }
        if ProcessInfo.processInfo.environment["NI_NOSENSOR"] != nil { simLux = 1000 }     // test hook: ignore the real light sensor
        fileLoad()
        view.onDragEnter = { [weak self] in self?.dragEntered = true }
        view.onDragExit = { [weak self] in self?.dragEntered = false }
        let dropped: ([URL]) -> Void = { [weak self] urls in
            guard let s = self else { return }
            s.fileAdd(urls)
            if let last = urls.last(where: { s.files.contains($0) }) { s.selected = .file(last) }   // the new file activity appears quietly
        }
        view.onDrop = dropped
        view.onScroll = { [weak self] e in self?.handleScroll(e) }
        for v in [view as FileDragView, rowView as FileDragView] {   // dragging a file out of the island
            v.fileForDrag = { [weak self] e in self?.fileForDrag(e) }
            v.onDragBegan = { [weak self] in self?.cancelPress() }
            v.onDragFinished = { [weak self] u, taken in if taken { self?.fileRemove(u) } }   // taken out: it leaves the pocket
        }
        c.fRevealB.target = self; c.fRevealB.action = #selector(revealFileTapped)
        c.fRemoveB.target = self; c.fRemoveB.action = #selector(removeFileTapped)
        c.hBar.onChange = { [weak self] v in self?.hudDragged(v) }
        c.progress.onScrub = { [weak self] f, final in self?.scrubbed(f, final: final) }
        view.dial.onDrag = { [weak self] dx, ph in self?.dialDragged(dx, ph) }
        view.onOpenSource = { [weak self] in self?.openSourceApp() }
        setupStatusItem()
        keyTap.onKey = { [weak self] code, down, fine in self?.handleMediaKey(code, down, fine) ?? false }
        setupKeyTap()
        if !UserDefaults.standard.bool(forKey: "hasSeenGuide") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showGuide() }
        }
        refreshUI()
        scheduleStep(busy: true)
        airMonitor.onChange = { [weak self] in self?.scheduleAirPodsRefresh() }
        airMonitor.start()
        watchOutputDevice()
        watchSleep()
        watchVolume()
        watchBattery()
        watchMusicApps()
        watchScreens()
        watchEscape()
        islandShortcut.onToggle = { [weak self] in
            guard NSApp.modalWindow == nil else { return }
            self?.menuToggleIsland()
        }
        islandShortcut.start()
        accessibilityLabels()
        let n0 = CFAbsoluteTimeGetCurrent()          // stagger the first polls so launch does not run every helper at once
        tMusic = n0 - 4; tAirPods = n0 - 25; tFiles = n0; tVolume = n0; tBattery = n0
    }

    // MARK: screen changes

    /// Display plugged / unplugged, resolution or arrangement changed: follow the notch screen and rebuild what is tied to it.
    func watchScreens() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let s = self else { return }
            let ns = App.pickScreen()
            s.screen = ns
            s.view.content.notchH = s.notchH
            s.link?.invalidate()
            s.link = ns.displayLink(target: s, selector: #selector(App.animTick(_:)))
            s.link?.add(to: .main, forMode: .common)
            s.link?.isPaused = false
            let r = s.frame(for: s.shape)
            s.mainP.x.jump(r.minX); s.mainP.w.jump(r.width); s.mainP.h.jump(r.height)
            s.mainP.x.tgt = r.minX; s.mainP.w.tgt = r.width; s.mainP.h.tgt = r.height
            s.atRest = false
            s.refreshUI()
        }
    }

    // MARK: Esc closes the open island

    func watchEscape() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let s = self, NSApp.modalWindow == nil else { return e }
            if e.keyCode == 53 && (s.pinned || s.hudActive), s.dismissIsland(clearHUD: true) {
                s.releaseKeyboardFocus(); return nil
            }
            guard s.panel.isKeyWindow, s.shape == .expanded else { return e }
            let modifiers = e.modifierFlags.intersection([.command, .control, .option])
            guard modifiers.isEmpty else { return e }
            if e.keyCode == 48 { KeyboardFocus.visible = true; s.advanceKeyboardSelection(backwards: e.modifierFlags.contains(.shift)); return nil }
            if [36, 76, 49].contains(e.keyCode), let button = s.panel.firstResponder as? NSButton {
                // Without a visible ring nothing looks focused, so Return / Space must not press the hidden first responder either.
                if KeyboardFocus.visible && !e.isARepeat && button.isEnabled { button.performClick(nil) }
                return nil
            }
            return e
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, let s = self, s.pinned else { return }      // 53 = Esc (needs the Accessibility permission, like the key tap)
            s.dismissIsland(clearHUD: true)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
            if KeyboardFocus.visible { KeyboardFocus.visible = false; NSApp.keyWindow?.contentView?.needsDisplay = true }   // the mouse takes over: no ring
            return e
        }
    }

    func accessibilityLabels() {
        let labels: [(NSButton, String)] = [(c.prevB, "이전 곡"), (c.playB, "재생 / 일시정지"), (c.nextB, "다음 곡"),
                                            (c.pauseB, "타이머 일시정지 / 계속"), (c.cancelB, "타이머 취소"),
                                            (c.fRevealB, "Finder에서 보기"), (c.fRemoveB, "주머니에서 빼기")]
        for (b, t) in labels { b.setAccessibilityLabel(t); b.toolTip = t }
        view.dial.setAccessibilityLabel("활동 전환")
        view.dial.toolTip = "드래그하거나 가로로 스크롤하여 활동 전환"
        c.hBar.setAccessibilityLabel("볼륨 / 밝기")
        c.progress.setAccessibilityLabel("재생 위치")
    }

    // MARK: event sources (instead of polling)

    private var volDev = AudioObjectID(0)
    private var volBlock: AudioObjectPropertyListenerBlock?
    private var batteryRL: CFRunLoopSource?
    private var musicDebounce: Timer?

    private func volAddresses() -> [AudioObjectPropertyAddress] {
        [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute].map {
            AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        }
    }
    /// Volume / mute changes of the current output device arrive as events; the slow poll is only a safety net.
    func watchVolume() {
        if let b = volBlock, volDev != 0 { for var a in volAddresses() { AudioObjectRemovePropertyListenerBlock(volDev, &a, .main, b) } }
        volBlock = nil; volDev = 0
        guard let d = SystemLevels.outputDevice() else { return }
        let b: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.pollVolume() }
        for var a in volAddresses() { AudioObjectAddPropertyListenerBlock(d, &a, .main, b) }
        volDev = d; volBlock = b
    }

    /// Plugging / unplugging and level changes arrive from IOKit: the banner shows at once and nothing polls.
    func watchBattery() {
        let cb: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let app = Unmanaged<App>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { app.pollBattery(); app.tBattery = CFAbsoluteTimeGetCurrent() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(cb, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes); batteryRL = src
        }
    }

    /// Music and Spotify announce every play / pause / track change: look up what is playing right then.
    func watchMusicApps() {
        let dc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            dc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let s = self else { return }
                s.musicDebounce?.invalidate()
                let t = Timer(timeInterval: 0.35, repeats: false) { [weak s] _ in s?.pollMusic(); s?.tMusic = CFAbsoluteTimeGetCurrent() }
                RunLoop.main.add(t, forMode: .common); s.musicDebounce = t
            }
        }
    }

    private var lastOutDev: AudioObjectID = 0
    private var outDebounce: Timer?

    /// Every real change of the default output (connect, disconnect, manual switch) starts the new output at zero volume
    /// (intended behavior, including when headphones are unplugged and the built-in speakers become the output),
    /// and refreshes the Bluetooth report. Opt out: `defaults write <bundle id> zeroVolumeOnOutputChange -bool NO`.
    func watchOutputDevice() {
        lastOutDev = SystemLevels.outputDevice() ?? 0
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            guard let s = self else { return }
            // Debounce: routing churn emits bursts of notifications; act once the output has settled.
            s.outDebounce?.invalidate()
            let t = Timer(timeInterval: 0.4, repeats: false) { [weak s] _ in s?.outputDeviceSettled() }
            RunLoop.main.add(t, forMode: .common); s.outDebounce = t
        }
    }

    private func outputDeviceSettled() {
        let dev = SystemLevels.outputDevice() ?? 0
        guard dev != lastOutDev else { return }          // same device re-announced: nothing to do
        lastOutDev = dev
        hudUntil = .distantPast
        lastVol = nil; lastMute = nil
        watchVolume()                                    // listen on the new device first, then change its level
        let enabled = UserDefaults.standard.object(forKey: "zeroVolumeOnOutputChange") as? Bool ?? true
        if enabled, !(demoVolume || demoBrightness) { SystemLevels.setVolume(0) }
        scheduleAirPodsRefresh()
    }

    /// Asleep or screen off: nothing is visible, so stop the main loop entirely until the Mac wakes.
    func watchSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.stepTimer?.invalidate(); self?.stepTimer = nil }
        }
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                guard let s = self, s.stepTimer == nil else { return }
                s.scheduleStep(busy: true)
            }
        }
    }

    /// The main loop runs at 60Hz only while something is on screen or moving; when the island rests it drops to 30Hz
    /// (the light sensor's own rate), with a little tolerance so the system can coalesce the wakeups.
    var stepTimer: Timer?, stepBusy = false
    func scheduleStep(busy: Bool) {
        stepTimer?.invalidate()
        stepBusy = busy
        let t = Timer(timeInterval: busy ? 1.0 / 60 : 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
        t.tolerance = busy ? 0.002 : 0.006
        RunLoop.main.add(t, forMode: .common)       // .common: also runs while a menu is open or a drag is in progress
        stepTimer = t
    }

    /// Something is visible, moving, pressed or dragged: needs the full frame rate.
    var stepNeedsFullRate: Bool {
        // a locked island that rests with nothing playing or counting needs no more than the idle rate
        let restingLocked = locked && shape == .expanded && atRest && lyricsWidthTransition == nil && media?.playing != true && !timer.running
        return (shape != .collapsed && !restingLocked) || !atRest || hudActive || pressing || dragActive || dropping || scrollHolding || alertText != nil || banner != nil
    }

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
            if !locked { return }
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
        if !locked && !p.isVisible { return }
        if locked {
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
        let target: CGFloat = locked ? 1 : 0
        if p.alphaValue != target && lockBorderTarget != target {
            lockBorderTarget = target
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = target }, completionHandler: { [weak self] in
                guard let self, !self.locked, p.alphaValue == 0 else { return }
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

    func symbolView(_ name: String, _ pt: CGFloat, _ tint: NSColor) -> NSImageView {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pt, weight: .semibold))
        v.contentTintColor = tint
        return v
    }

    /// The slot views of an activity. Files get theirs on demand: the file's own icon, nothing else.
    func slotItem(_ k: ActKind) -> SlotItem? {
        if let it = slotItems[k] { return it }
        guard case .file(let u) = k else { return nil }
        let icon = FilePreviewView()
        icon.setFile(u)
        let it = SlotItem(icon: icon, detail: NSView(), detailSize: .zero)
        slotItems[k] = it
        return it
    }

    func makeSlotItems() {
        slotItems[.media] = SlotItem(icon: ArtView(radius: 6), detail: EqView(), detailSize: CGSize(width: 20, height: 16))
        slotItems[.timer] = SlotItem(icon: TimerRing(),
                                     detail: makeLabel(13, .semibold, accent, mono: true, align: .right), detailSize: CGSize(width: 46, height: 18))
        slotItems[.charging] = SlotItem(icon: symbolView("bolt.fill", 15, bannerGreen),
                                        detail: makeLabel(13, .semibold, bannerGreen, mono: true, align: .center), detailSize: CGSize(width: 38, height: 18))
        slotItems[.lowBattery] = SlotItem(icon: symbolView("battery.25percent", 16, bannerRed),
                                          detail: makeLabel(13, .semibold, bannerRed, mono: true, align: .center), detailSize: CGSize(width: 38, height: 18))
        slotItems[.airpods] = SlotItem(icon: symbolView("airpods", 17, .white), detail: RingView(), detailSize: CGSize(width: 24, height: 24))
    }

    /// Demos: a stopwatch, or (NI_COUNTDOWN=1) a one-minute timer.
    func startDemoTimer() {
        if ProcessInfo.processInfo.environment["NI_COUNTDOWN"] != nil { timer.startCountdown(minutes: 1) } else { timer.toggle() }
    }

    /// The one place that closes the open island on the user's behalf (outside click, Esc, Cmd+., sensor, notch tap).
    /// A locked island refuses; new dismiss paths go through here instead of repeating the `locked` check.
    @discardableResult func dismissIsland(clearHUD: Bool = false, keepPinned: Bool = false) -> Bool {
        guard !locked else { return false }
        if clearHUD && hudActive { hudUntil = .distantPast }
        if !keepPinned { pinned = false; alertText = nil; banner = nil }
        return true
    }

    func wire(_ b: NSButton, _ sel: Selector) { b.target = self; b.action = sel }

    // MARK: actions

    @objc func prevTapped() { if demoMedia { return }; sendMediaCommand(5); pollSoon() }
    @objc func nextTapped() { if demoMedia { return }; sendMediaCommand(4); pollSoon() }
    @objc func playPauseTapped() {
        var wantPlay = true
        if var m = media {                           // flip the icon at once; the poll after the command confirms it
            m.elapsed = m.elapsedNow; m.readAt = Date(); m.playing.toggle()
            wantPlay = m.playing
            if m.playing { lastPlayingAt = Date() }
            media = m
        }
        if !demoMedia {
            playTapGeneration += 1
            let generation = playTapGeneration
            playHoldUntil = Date().addingTimeInterval(2.5)    // polls that still show the old state are ignored meanwhile
            sendMediaCommand(wantPlay ? 0 : 1) { [weak self] in    // explicit play / pause: a toggle can land the wrong way
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.confirmPlayState(wantPlay, retry: true, generation: generation) }
            }
        }
        refreshUI()
    }
    /// If the player ignored the command (no MediaRemote client), press the media key once, then take the real state.
    /// A newer tap supersedes this check, so a stale `wantPlay` can never press the key against the user's last intent.
    func confirmPlayState(_ wantPlay: Bool, retry: Bool, generation: Int) {
        guard generation == playTapGeneration else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = queryNowPlaying()
            DispatchQueue.main.async {
                guard let self, generation == self.playTapGeneration else { return }
                if retry, case .media(let m) = r, m.playing != wantPlay, m.trackID == self.media?.trackID {
                    postPlayPauseKey()
                    self.pollSoon()                      // the regular poll reports the outcome; the hold covers the gap
                    return
                }
                self.playHoldUntil = .distantPast
                self.applyPolled(r)
            }
        }
    }
    // MARK: menu bar item

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "NotchIsland")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        if ProcessInfo.processInfo.environment["NI_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let w = item.button?.window
                FileHandle.standardError.write("status item: visible=\(item.isVisible) window=\(String(describing: w?.frame)) onscreen=\(w?.isVisible ?? false) screen=\(String(describing: w?.screen?.frame))\n".data(using: .utf8)!)
            }
        }
    }

    /// Rebuilt every time it opens, so the items match what is running right now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector, _ tag: Int = 0, key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self; i.tag = tag; menu.addItem(i)
        }
        if timer.started {
            menu.addItem(withTitle: (timer.mode == .stopwatch ? "스톱워치 " : "타이머 ") + timer.text(), action: nil, keyEquivalent: "").isEnabled = false
            add(timer.finished ? "다시 시작" : (timer.running ? "일시정지" : "계속"), #selector(menuToggleTimer))
            add("취소", #selector(menuCancelTimer))
        } else {
            add("스톱워치 시작", #selector(menuStopwatch))
            let sub = NSMenu()
            for m in [1, 3, 5, 10, 15, 30] {
                let i = NSMenuItem(title: "\(m)분", action: #selector(menuCountdown(_:)), keyEquivalent: "")
                i.target = self; i.tag = m; sub.addItem(i)
            }
            sub.addItem(.separator())
            let custom = NSMenuItem(title: "직접 입력…", action: #selector(menuCustomTimer), keyEquivalent: "")
            custom.target = self; sub.addItem(custom)
            let parent = NSMenuItem(title: "타이머", action: nil, keyEquivalent: "")
            parent.submenu = sub; menu.addItem(parent)
        }
        if !actOrder.isEmpty {
            add(pinned ? "활동 닫기" : "활동 열기", #selector(menuToggleIsland), key: ".")
            if actOrder.count > 1 {
                add("이전 활동", #selector(menuPreviousActivity), key: "[")
                add("다음 활동", #selector(menuNextActivity), key: "]")
            }
            let activities = NSMenu()
            for (index, kind) in actOrder.enumerated() {
                let item = NSMenuItem(title: activityName(kind), action: #selector(menuSelectActivity(_:)), keyEquivalent: "")
                item.target = self; item.tag = index
                item.state = kind == cardKind && pinned ? .on : .off
                activities.addItem(item)
            }
            let parent = NSMenuItem(title: "활동 목록 (\(actOrder.count))", action: nil, keyEquivalent: "")
            parent.submenu = activities; menu.addItem(parent)
        }
        if !files.isEmpty { add("주머니 비우기 (\(files.count))", #selector(filesClear)) }
        if !clearedFiles.isEmpty { add("주머니 비우기 취소", #selector(restoreClearedFiles), key: "z") }
        menu.addItem(.separator())
        add("사용법", #selector(menuGuide))
        add(AXIsProcessTrusted() ? "접근성 권한 허용됨" : "접근성 권한 설정…", #selector(menuAccessibility))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "NotchIsland 종료", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
    }

    func activityName(_ kind: ActKind) -> String {
        switch kind {
        case .media: return "미디어: \(media?.title ?? "재생 중")"
        case .timer: return timer.finished ? "타이머 완료" : "타이머: \(timer.text())"
        case .charging: return "충전 중"
        case .lowBattery: return "배터리 부족"
        case .airpods: return "AirPods"
        case .file(let url): return "파일: \(url.lastPathComponent)"
        }
    }

    @objc func menuToggleIsland() {
        if pinned || hudActive {
            guard dismissIsland(clearHUD: true) else { return }      // locked: Cmd+. does not close it
            selected = nil
            releaseKeyboardFocus()
        } else if let kind = acts.first { selected = kind; pinned = true }
        else { showAlert("실행 중인 활동이 없습니다", seconds: 4) }
        refreshUI(); applyShape()
        if pinned { focusIsland() }
    }
    var keyboardControls: [NSView] {
        let controls: [NSView]
        switch body {
        case .media: controls = [c.prevB, c.playB, c.nextB, c.lyricsB, c.progress]
        case .timer: controls = [c.pauseB, c.cancelB]
        case .file: controls = [c.fRevealB, c.fRemoveB]
        case .hud: controls = [c.hBar]
        default: controls = []
        }
        return controls.filter { !$0.isHidden && (($0 as? NSControl)?.isEnabled ?? true) }
    }
    func releaseKeyboardFocus() {
        KeyboardFocus.visible = false
        panel.resignKey()
        let previous = keyboardReturnApp
        keyboardReturnApp = nil
        if let previous, !previous.isTerminated { previous.activate(options: []) }
    }
    func focusIsland() {
        KeyboardFocus.visible = false
        if let previous = NSWorkspace.shared.frontmostApplication, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            keyboardReturnApp = previous
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        let controls = keyboardControls
        for (index, control) in controls.enumerated() { control.nextKeyView = controls[(index + 1) % controls.count] }
        panel.makeFirstResponder(controls.first ?? view)
    }
    func advanceKeyboardSelection(backwards: Bool) {
        let controls = keyboardControls
        guard !controls.isEmpty else { return }
        let current = controls.firstIndex { $0 === panel.firstResponder }
        let index = current.map { ($0 + (backwards ? -1 : 1) + controls.count) % controls.count } ?? (backwards ? controls.count - 1 : 0)
        let previous = panel.firstResponder as? NSView
        panel.makeFirstResponder(controls[index])
        previous?.needsDisplay = true; controls[index].needsDisplay = true
    }
    func moveActivity(_ offset: Int) {
        guard !actOrder.isEmpty else { return }
        let current = cardKind.flatMap { actOrder.firstIndex(of: $0) } ?? 0
        let index = (current + offset + actOrder.count) % actOrder.count
        let item = NSMenuItem(); item.tag = index; menuSelectActivity(item)
    }
    @objc func menuPreviousActivity() { moveActivity(-1) }
    @objc func menuNextActivity() { moveActivity(1) }

    @objc func menuSelectActivity(_ sender: NSMenuItem) {
        guard actOrder.indices.contains(sender.tag) else { return }
        let kind = actOrder[sender.tag]
        selected = kind; banner = nil; alertText = nil; pinned = true
        refreshUI(); applyShape()
        focusIsland()
    }

    @objc func menuGuide() { showGuide() }
    func showGuide() {
        UserDefaults.standard.set(true, forKey: "hasSeenGuide")
        let alert = NSAlert()
        alert.messageText = "NotchIsland 사용법"
        alert.informativeText = "노치를 클릭하거나 Command + .으로 열고 닫습니다. 펼친 상태에서 Tab / Shift + Tab으로 선택하고 Enter 또는 Space로 실행합니다. 슬라이더는 좌우 방향키로 조절합니다. 여러 활동은 아래 다이얼을 드래그하거나 가로로 스크롤해 전환합니다. 음악 카드에서 가로 스크롤하면 재생 위치가 이동합니다. 파일을 노치로 드래그해 보관하고, 메뉴 막대의 활동 목록에서 모든 항목을 열 수 있습니다.\n\n미디어 키와 Esc로 닫기에는 접근성 권한이 필요합니다. 권한 없이도 나머지 기능을 사용할 수 있습니다."
        alert.addButton(withTitle: "확인")
        if !AXIsProcessTrusted() { alert.addButton(withTitle: "접근성 권한 설정") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { requestAccessibility() }
    }

    func requestAccessibility() {
        if AXIsProcessTrusted() { return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func menuAccessibility() { requestAccessibility() }

    @objc func menuCustomTimer() {
        let alert = NSAlert()
        alert.messageText = "타이머 직접 설정"
        alert.informativeText = "시간을 분 단위로 입력하세요 (1~1440분)."
        alert.addButton(withTitle: "시작"); alert.addButton(withTitle: "취소")
        let input = NSTextField(string: "5")
        input.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            if let minutes = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), (1...1440).contains(minutes) {
                timer.startCountdown(minutes: minutes); refreshUI(); return
            }
            alert.informativeText = "1부터 1440까지의 정수를 입력하세요."
        }
    }

    @objc func menuStopwatch() { timer.startStopwatch(); refreshUI() }
    @objc func menuCountdown(_ sender: NSMenuItem) { timer.startCountdown(minutes: sender.tag); refreshUI() }
    @objc func menuToggleTimer() { timer.toggle(); refreshUI() }
    @objc func menuCancelTimer() { timer.reset(); refreshUI() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    /// Bring the app that is playing to the front (Music, Spotify, the browser with the video...).
    func openSourceApp() {
        guard let id = media?.bundleID, !id.isEmpty else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            running.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        pinned = false                               // go back to the compact island once the app is in front
    }

    @objc func timerToggleTapped() { timer.toggle(); refreshUI() }
    @objc func timerCancelTapped() { timer.reset(); refreshUI() }
    func pollSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pollMusic() } }

    /// Which activity is under the pointer. Anything on the notch itself or to the left of it is the activity attached
    /// to the notch on the left (the first one); the right wing, the detached icon and the pill pick their own.
    func kindAtMouse() -> ActKind? {
        let a = acts
        guard !a.isEmpty else { return nil }
        let m = NSEvent.mouseLocation
        if !rowView.isHidden, a.count >= 3 {
            let point = rowView.convert(panel.convertPoint(fromScreen: m), from: nil)
            if rowView.bounds.contains(point) {
                let items = Array(a.dropFirst(2))
                if let index = rowView.itemFrames.firstIndex(where: { $0.contains(point) }), items.indices.contains(index) { return items[index] }
                return nil
            }
        }
        if shape == .expanded {
            let point = c.convert(panel.convertPoint(fromScreen: m), from: nil)
            if let left = lastPlan?.left, c.leftView?.frame.contains(point) == true { return left }
            if let right = lastPlan?.right, c.rightView?.frame.contains(point) == true { return right }
            return nil
        }
        if a.count >= 2, m.x > notchRight { return a[1] }
        return a[0]
    }

    /// Finger down: react at once (swell; the trackpad's own click is the only haptic). With something running, a quick tap opens it on release,
    /// and holding opens it after 0.25s without waiting for the release. With nothing running it pops out and back.
    func pressBegan() {
        pressKind = kindAtMouse()
        pressedWhileExpanded = (shape == .expanded)
        if pressedWhileExpanded { return }           // already open: the release (a tap) closes it
        if !liveActivity {                           // nothing to show: pop out a little and go straight back in
            popUntil = Date().addingTimeInterval(0.22)
            return
        }
        pressing = true
        longPressTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let s = self, s.pressing else { return }
            let zone = s.frame(for: s.shape)
            guard zone.insetBy(dx: -40, dy: -40).contains(NSEvent.mouseLocation) else { return }   // dragged away while holding: do nothing
            s.pressing = false
            s.selected = s.pressKind
            s.pinned = true                          // popped out: stays out until you click elsewhere
        }
        RunLoop.main.add(t, forMode: .common)
        longPressTimer = t
    }

    func pressEnded(inside: Bool) {
        longPressTimer?.invalidate(); longPressTimer = nil
        let wasPressing = pressing
        pressing = false
        if wasPressing && inside && liveActivity {   // a quick tap (trackpad click / tap-to-click) opens it
            selected = pressKind
            pinned = true
        }
        if pressedWhileExpanded && inside {
            if let kind = pressKind, kind != cardKind {
                selected = kind; pinned = true; refreshUI(); return
            }
            if hudActive { hudUntil = .distantPast }
            else if overRealNotch && pinned { locked.toggle(); swellSuppressed = locked; haptic(.levelChange) }   // tap the real notch again: lock / unlock (only a pinned island can lock)
            else { dismissIsland() }
        }
        pressedWhileExpanded = false
    }

    // MARK: sensor touch (covering the ambient light sensor)

    /// Covered. Open island -> shrinks back. Nothing running -> pops out and straight back in.
    /// Something running -> reacts at once; keep it covered 0.3s and it pops open and stays.
    func sensorTouchBegan() {
        haptic(.alignment)
        if shape == .expanded || pinned {
            if hudActive { guard dismissIsland(clearHUD: true, keepPinned: true) else { return } }
            else { guard dismissIsland() else { return } }
            haptic(.levelChange)
            return
        }
        if !liveActivity { popUntil = Date().addingTimeInterval(0.22); return }
        pressing = true
        longPressTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let s = self, s.pressing, s.darkLatched else { return }   // still covered
            s.pressing = false
            s.selected = s.acts.first                // touching the sensor picks the activity attached to the notch (left)
            s.pinned = true
            haptic(.levelChange)
        }
        RunLoop.main.add(t, forMode: .common)
        longPressTimer = t
    }

    /// Uncovered before the long press fired: just settles back.
    func sensorTouchEnded() {
        longPressTimer?.invalidate(); longPressTimer = nil
        pressing = false
    }

    @objc func lyricsTapped() {
        guard supportsLyrics else { return }
        let animateWidth = shape == .expanded && body == .media && mainP.w.cur > 0
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fromWidth = mainP.w.cur
        lyricsRequested.toggle()
        if lyricsRequested {
            selected = .media; pinned = true
            lyrics.select(lyricsTrack)
            lyrics.requestNow()                      // asked for explicitly: no waiting for a back-off
            lyrics.refreshIfNeeded()
        }
        if animateWidth {
            lyricsWidthTransition = LyricsWidthTransition(from: Double(fromWidth), to: Double(frame(for: .expanded).width), start: hardwareSeconds())
            mainP.w.vel = 0
        }
        refreshUI(); applyShape()
    }

    // MARK: files (the pocket)

    func fileAdd(_ urls: [URL]) {
        for u in urls where !files.contains(u) { files.append(u) }
        syncActivities(); fileSave(); refreshUI()
    }
    func fileRemove(_ u: URL) {
        files.removeAll { $0 == u }; slotItems.removeValue(forKey: .file(u))
        syncActivities(); fileSave(); refreshUI()
    }
    @objc func filesClear() {
        clearedFiles = files
        for u in files { slotItems.removeValue(forKey: .file(u)) }
        files.removeAll(); syncActivities(); fileSave(); refreshUI()
    }
    @objc func restoreClearedFiles() {
        fileAdd(clearedFiles); clearedFiles = []
    }
    func fileSave() {
        guard demoShelf == nil else { return }
        UserDefaults.standard.set(files.map { $0.path }, forKey: "pocketFiles")
    }
    func fileLoad() {
        let paths = demoShelf ?? UserDefaults.standard.stringArray(forKey: "pocketFiles") ?? []
        files = paths.map { URL(fileURLWithPath: $0) }
    }
    @objc func revealFileTapped() { if case .file(let u)? = cardKind { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc func removeFileTapped() { if case .file(let u)? = cardKind { fileRemove(u); pinned = false } }

    func fileSubtitle(_ u: URL) -> String {
        guard FileManager.default.fileExists(atPath: u.path) else { return "연결을 확인하세요 · 파일에 접근할 수 없음" }
        if let c = fileInfo[u] { return c }
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let info = [u.deletingLastPathComponent().lastPathComponent, size].compactMap { $0 }.joined(separator: " · ")
        fileInfo[u] = info
        return info
    }

    /// The file a drag starting at the pointer would carry: the open file card's icon / name, or a file icon in the compact island.
    func fileForDrag(_ e: NSEvent) -> URL? {
        if shape == .expanded {
            guard body == .file, case .file(let u)? = cardKind else { return nil }
            return c.fIcon.frame.union(c.fName.frame).contains(c.convert(e.locationInWindow, from: nil)) ? u : nil
        }
        if case .file(let u)? = kindAtMouse() { return u }
        return nil
    }
    func cancelPress() { longPressTimer?.invalidate(); longPressTimer = nil; pressing = false }

    /// Called every frame: is a file drag (from Finder...) in progress, and is it near the notch?
    func trackFileDrag(_ m: NSPoint) {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down && !wasBtn { downChange = NSPasteboard(name: .drag).changeCount; dragActive = false }
        if down, !dragActive {                          // the drag pasteboard is only looked at while the button is held
            let pb = NSPasteboard(name: .drag)
            if pb.changeCount != downChange, pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { dragActive = true }
        }
        if !down { dragActive = false; dragEntered = false }
        wasBtn = down
        let zone = dropping ? frame(for: .expanded).insetBy(dx: -30, dy: -30)
                            : NSRect(x: screen.frame.midX - 110, y: screen.frame.maxY - 70, width: 220, height: 70)
        let near = dragActive && zone.contains(m)
        if near != dragNear { dragNear = near }
    }

    // MARK: volume / brightness HUD

    func showHUD(_ kind: LevelKind, _ value: Float, muted: Bool = false, seconds: TimeInterval = 1.8) {
        hudKind = kind; hudValue = value; hudMuted = muted
        hudUntil = Date().addingTimeInterval(seconds)
        refreshUI()
    }

    /// Volume changed by something else (menu bar slider, headphones, another app): show it too.
    func pollVolume() {
        guard let v = SystemLevels.volume() else { return }
        let muted = SystemLevels.muted() ?? false
        lastVol = v; lastMute = muted
        // Core Audio reports a value change, not whether a human or adaptive audio caused it.
        // Only refresh an existing HUD; new HUDs require an intercepted key or our slider.
        if hudActive && hudKind == .volume { hudValue = v; hudMuted = muted || v < 0.001 }
    }

    /// Media keys, once the Accessibility permission has been granted. Returns true when the key was handled.
    func handleMediaKey(_ code: Int, _ down: Bool, _ fine: Bool) -> Bool {
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        func snap(_ v: Float) -> Float { (v / step).rounded() * step }
        switch code {
        case 0, 1, 7:                                                          // volume up / down, mute
            guard SystemLevels.volumeControllable else { return false }         // e.g. HDMI output: leave it to the system
            guard down else { return true }
            let wasMuted = SystemLevels.muted() ?? false
            let cur = SystemLevels.volume() ?? 0
            if code == 7 {
                let now = !wasMuted
                if SystemLevels.setMuted(now) {
                    showHUD(.volume, cur, muted: now || cur < 0.001)
                } else {
                    if cur > 0.001 { lastAudibleVolume = cur }
                    let value: Float = cur > 0.001 ? 0 : lastAudibleVolume
                    guard SystemLevels.setVolume(value) else { return false }
                    showHUD(.volume, value, muted: value < 0.001)
                }
                return true
            }
            if wasMuted { SystemLevels.setMuted(false) }
            let nv = min(1, max(0, snap(cur) + (code == 0 ? step : -step)))
            guard SystemLevels.setVolume(nv) else { return false }
            showHUD(.volume, nv, muted: nv < 0.001)
            return true
        case 2, 3:                                                             // brightness up / down
            guard SystemLevels.brightnessControllable else { return false }
            guard down else { return true }
            let cur = brightTarget ?? SystemLevels.brightness() ?? 0     // chain presses from where the glide is heading
            let nb = min(1, max(0, snap(cur) + (code == 2 ? step : -step)))
            rampBrightness(to: nb)
            showHUD(.brightness, nb)
            return true
        default:
            return false                                                       // keyboard backlight etc.: untouched
        }
    }

    /// Eases the real brightness to `t` (~0.25s) instead of jumping a whole step at once.
    func rampBrightness(to t: Float) {
        brightTarget = t
        guard brightTimer == nil else { return }
        brightCur = SystemLevels.brightness() ?? t
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let s = self, let target = s.brightTarget else { tm.invalidate(); self?.brightTimer = nil; return }
            let d = target - s.brightCur
            if abs(d) < 0.004 {
                s.brightCur = target; SystemLevels.setBrightness(target)
                s.brightTarget = nil; tm.invalidate(); s.brightTimer = nil
                return
            }
            s.brightCur += d * 0.22                                            // ease-out
            SystemLevels.setBrightness(s.brightCur)
        }
        RunLoop.main.add(timer, forMode: .common); brightTimer = timer
    }

    /// The pointer set the level on the HUD bar.
    func hudDragged(_ v: Float) {
        let demo = demoVolume || demoBrightness                                 // demos never touch the real levels
        switch hudKind {
        case .volume:
            if !demo { if SystemLevels.muted() == true { SystemLevels.setMuted(false) }; SystemLevels.setVolume(v) }
            showHUD(.volume, v, muted: v < 0.001, seconds: 1.8)
        case .brightness:
            brightTarget = nil                                                  // cancel any glide: follow the pointer directly
            if !demo { SystemLevels.setBrightness(v) }
            showHUD(.brightness, v, seconds: 1.8)
        }
    }

    func setupKeyTap() {
        guard ProcessInfo.processInfo.environment["NI_NOKEYTAP"] == nil else { return }     // test hook
        func tryInstall() {
            if !keyTap.isActive, AXIsProcessTrusted(), keyTap.install(),
               ProcessInfo.processInfo.environment["NI_DEBUG"] != nil {
                FileHandle.standardError.write("media key tap installed\n".data(using: .utf8)!)
            }
        }
        tryInstall()
        let kt = Timer(timeInterval: 5, repeats: true) { _ in tryInstall() }   // picks up a later grant
        kt.tolerance = 2
        RunLoop.main.add(kt, forMode: .common); keyTapTimer = kt
    }

    func showBanner(_ k: BannerKind, autoHide: TimeInterval? = nil, feedback: Bool = true) {
        banner = k
        bannerHideAt = Date().addingTimeInterval(autoHide ?? 4)
        pinned = true
        if feedback { haptic(.levelChange) }
    }

    func showAlert(_ text: String, seconds: TimeInterval = 3.5) {
        if let cur = alertText, Date() < alertUntil, cur != text { alertText = cur + "  ·  " + text }   // merge simultaneous alerts
        else { alertText = text }
        alertUntil = Date().addingTimeInterval(seconds)
        pinned = true                                // alerts open it and it stays until an outside click
        haptic(.levelChange)
    }

    // MARK: periodic work

    var tAppearance = 0.0, tFiles = 0.0, tVolume = 0.0, tBattery = 0.0, tMusic = 0.0, tAirPods = 0.0
    /// True (and re-arms `last`) when `every` seconds have passed since it last was.
    func due(_ last: inout Double, _ every: Double) -> Bool {
        let n = CFAbsoluteTimeGetCurrent()
        guard n - last >= every else { return false }
        last = n; return true
    }

    func step() {
        tick += 1
        let now = Date()

        // hover: pointer inside the current shape (a little padded) nudges the island
        let m = NSEvent.mouseLocation
        let pad: CGFloat = shape == .expanded ? 8 : 4
        let hit = frame(for: shape).insetBy(dx: -pad, dy: -pad)
        let probe = NSRect(x: hit.minX, y: hit.minY, width: hit.width, height: hit.height + 4) // include the screen's top edge
        if probe.contains(m) {
            hoverUntil = now.addingTimeInterval(0.25)
            if case .airpods? = banner, let expires = bannerHideAt { bannerHideAt = max(expires, now.addingTimeInterval(1.2)) }
            if hudActive { hudUntil = max(hudUntil, now.addingTimeInterval(0.9)) }   // pointer on the HUD: keep it
        }
        let overHUD = hudActive && probe.contains(m)
        if c.hBar.sliderMode != overHUD { c.hBar.sliderMode = overHUD }              // cells melt into a slider under the pointer

        if !stepBusy || tick % 2 == 0 {            // 30Hz in both modes: the ambient light sensor is the touch sensor
            let v = simLux ?? als_read()              // simLux is only set by the test hook below
            if v >= 0 { lux = v; sensorMisses = 0 }   // raw value, no smoothing; hysteresis below prevents flicker
            else { sensorMisses += 1; if sensorMisses >= 60 { lux = -1 } }   // ~2s of silence: stop trusting old data
            let wasCovered = darkLatched
            // in a dim room covering the sensor hardly changes the reading: the bar follows the room's own light (but never above `threshold`)
            let thr = max(2, ambient > 0 ? min(threshold, ambient * 0.3) : threshold)
            if lux >= 0 && lux < thr { darkLatched = true }                  // covered  = finger down
            else if lux < 0 || lux > thr * 1.2 { darkLatched = false }       // uncovered = finger up
            if !darkLatched && lux >= 0 { ambient = ambient < 0 ? lux : ambient * 0.98 + lux * 0.02 }
            if darkLatched && !wasCovered { sensorTouchBegan() }
            else if !darkLatched && wasCovered { sensorTouchEnded() }
        }
        if let t = bannerHideAt, now > t {                      // a timed banner (AirPods connecting) goes away by itself
            bannerHideAt = nil
            banner = nil; if selected == nil && alertText == nil { pinned = false }
        }
        if alertText != nil && now >= alertUntil {
            alertText = nil
            if selected == nil && banner == nil { pinned = false }
        }
        if mainP.m.cur > 0.5 || mainP.m.tgt > 0 {             // only the island and the dial take the pointer; the margin is click-through
            let pf = panel.frame, mp = NSEvent.mouseLocation
            let bodyR = NSRect(x: pf.minX, y: pf.minY + mainP.m.cur, width: pf.width, height: pf.height - mainP.m.cur)
            let stripR = NSRect(x: pf.minX, y: pf.minY, width: pf.width, height: mainP.m.cur + 8)
            let ign = !(bodyR.contains(mp) || stripR.contains(mp) || (scrollHolding && pf.contains(mp)))
            if panel.ignoresMouseEvents != ign { panel.ignoresMouseEvents = ign }
        } else if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
        if due(&tAppearance, 2) { view.dial.lightAppearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua }   // tick colour follows light / dark mode
        trackFileDrag(NSEvent.mouseLocation)
        if due(&tFiles, 5) { fileInfo.removeAll(); c.fileShown = nil }
        if due(&tVolume, 2) { pollVolume() }       // safety net only: volume changes normally arrive as events (watchVolume)
        if lyricsVisible {
            lyrics.refreshIfNeeded()
            let time = lyricsPlaybackTime
            if c.lyricsPane.needsAdvance(at: time) { c.lyricsPane.advance(to: time) }   // paused and settled: nothing to draw
        }
        if due(&tBattery, 5) { pollBattery() }     // safety net; battery changes normally arrive from IOKit (watchBattery)
        // each lookup spawns osascript: poll faster only while a track is playing or the card is open
        if due(&tMusic, shape == .expanded ? 2 : (media?.playing == true ? 3 : 5)) { pollMusic() }
        if let m = media, !m.playing, !demoMedia, demoActsN == nil, shape != .expanded,
           now.timeIntervalSince(lastPlayingAt) > 4 { media = nil }     // paused for a while: let it go
        if due(&tAirPods, 12) { pollAirPods() }    // system_profiler is heavy; a new output device triggers it sooner (see watchOutputDevice)

        
        prevTimerStarted = timer.started
        if timer.running && timer.finished {
            timer.toggle() // Keep the completed activity until it is dismissed or restarted.
            selected = .timer; pinned = true
            NSSound.beep(); haptic(.levelChange); refreshUI()
        }

        if !liveActivity && shape == .collapsed && atRest && !pinned && !stepBusy {
            if !idleRefreshed { idleRefreshed = true; refreshUI() }     // resting and empty: one last refresh, then nothing to redraw
        } else {
            idleRefreshed = false
            if tick % (stepBusy ? 6 : 3) == 0 { refreshUI() }           // content at 10Hz; shape/hover/press every frame
        }
        applyShape()
        if stepNeedsFullRate != stepBusy { scheduleStep(busy: !stepBusy) }
    }

    func pollBattery() {
        guard let b = readBattery() else { return }
        applyBattery(b)
    }

    func applyBattery(_ b: Battery) {
        let event = batteryNotifications.update(b)
        if let old = battery, old.plugged != b.plugged, case .battery? = banner {
            // Remove a stale charging/low-battery banner when the power source changes.
            banner = nil
            bannerHideAt = nil
            if selected == nil && alertText == nil { pinned = false }
        }
        if event == nil, b.plugged, let old = battery,
           case .battery(let title, _, _)? = banner, title == old.connectionTitle {
            // Correct a delayed charging flag without restarting the transient banner.
            banner = .battery(title: b.connectionTitle, level: b.level, color: bannerGreen)
        }
        battery = b
        switch event {
        case .connected:
            showBanner(.battery(title: b.connectionTitle, level: b.level, color: bannerGreen),
                       autoHide: 3, feedback: false)
        case .lowBattery:
            showBanner(.battery(title: "배터리 부족", level: b.level, color: bannerRed), autoHide: 3)
        case nil:
            break // Disconnecting, reaching full charge and charge holds stay quiet.
        }
    }

    func scheduleAirPodsRefresh(after delay: TimeInterval = 0.6) {
        airRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pollAirPods() }
        airRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func pollAirPods() {
        guard !airBusy else { airRefreshPending = true; return }
        airBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = queryAirPods()
            DispatchQueue.main.async {
                guard let self else { return }
                self.airBusy = false
                self.applyAirPods(list)
                if self.airRefreshPending { self.airRefreshPending = false; self.scheduleAirPodsRefresh() }
            }
        }
    }

    func applyAirPods(_ list: [AirPodsInfo]?) {
        let previousIDs = Set(airConnections.devices.keys)
        let changes = airConnections.update(list)
        airList = Array(airConnections.devices.values)
        for (device, connected) in changes {
            showBanner(.airpods(symbol: device.symbol, level: connected ? device.level : nil,
                                name: device.name, connected: connected), autoHide: connected ? 7 : 5)
        }
        // Confirm absences with a second successful report; transient errors preserve the baseline.
        if let list, !previousIDs.subtracting(Set(list.map { $0.id })).isEmpty {
            scheduleAirPodsRefresh()
        }
        if list == nil {
            airFailures += 1
            scheduleAirPodsRefresh(after: min(30, pow(2, Double(min(airFailures, 5)))))
        } else { airFailures = 0 }
        if case .airpods(_, _, let name, true)? = banner,
           let device = airList.first(where: { $0.name == name }) {
            banner = .airpods(symbol: device.symbol, level: device.level, name: device.name)
        }
    }

    func pollMusic() {
        guard !musicBusy, !demoMedia, demoActsN == nil, ProcessInfo.processInfo.environment["NI_NOMEDIA"] == nil else { return }   // NI_NOMEDIA=1: test hook
        musicBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = queryNowPlaying()
            DispatchQueue.main.async { self?.applyPolled(r); self?.musicBusy = false }
        }
    }

    func applyPolled(_ result: PollResult) {
        let r: Media
        switch result {
        case .failed: return                         // a failed lookup must not make the island vanish
        case .nothing:
            nothingPolls += 1                            // a track change can answer 'nothing' for a moment: wait for a second answer
            if nothingPolls >= 2 || media?.playing == false { media = nil }
            mediaBaseline = true; return
        case .media(let m): r = m; nothingPolls = 0
        }
        defer { mediaBaseline = true }
        // a poll of the same track that still shows the old state; a new track is real news
        if Date() < playHoldUntil, case .media(let n) = result, n.playing != media?.playing, n.trackID == media?.trackID { return }
        if Date() < seekHoldUntil, case .media(let n) = result, media != nil, n.trackID == media?.trackID { return }   // stale position right after a seek
        if r.playing { lastPlayingAt = Date() }
        // keep a paused track around for a while so it can be resumed from the island
        // A paused track is only KEPT while it is already showing (so it can be resumed from the island).
        // Once it has gone away it never comes back by itself: only playing again starts a new activity.
        if !r.playing {
            guard media != nil, shape == .expanded || Date().timeIntervalSince(lastPlayingAt) < 4 else { media = nil; return }
        }
        let started = media == nil                   // playback just started (a track change alone never opens the card)
        media = r
        loadArtwork(for: r)
        _ = started                                  // a new music activity appears quietly: it never opens the card by itself
    }

    var artRetryAt: [String: Date] = [:], artTries: [String: Int] = [:]
    func artworkKey(_ m: Media) -> String { m.storeID.isEmpty ? "t:\(m.title)|\(m.artist)" : m.storeID }

    func loadArtwork(for m: Media) {
        let id = artworkKey(m)
        guard id != artworkFor else { return }
        if let t = artRetryAt[id], Date() < t { return }              // a failed lookup is retried later, not on every poll
        artworkFor = id
        // keep showing the previous cover until the new one has arrived, so it fades once instead of flashing
        if let hit = artCache[id] { artwork = hit.0; artColor = hit.1; return }
        let tries = artTries[id, default: 0]
        artTries[id] = tries + 1
        let done: (NSImage?) -> Void = { [weak self] img in
            guard let s = self else { return }
            guard let img = img else {
                DispatchQueue.main.async {
                    guard s.artworkFor == id else { return }
                    s.artwork = nil; s.artColor = accent
                    if m.storeID.isEmpty && tries >= 1 { return }      // no cover to be had for this track (at most two tries)
                    s.artworkFor = ""; s.artRetryAt[id] = Date().addingTimeInterval(30)
                    if m.storeID.isEmpty { s.artwork = nil; s.artColor = accent }
                }
                return
            }
            let col = playbackColor(from: img)
            DispatchQueue.main.async {
                s.artCache[id] = (img, col)
                if s.artCache.count > 40 { s.artCache.removeValue(forKey: s.artCache.keys.first!) }
                if s.artworkFor == id { s.artwork = img; s.artColor = col }
            }
        }
        if m.storeID.isEmpty {                                        // Spotify, browsers...: the cover comes with the now-playing info
            artwork = nil; artColor = accent
            DispatchQueue.global(qos: .utility).async { done(queryArtworkData()) }
        } else {
            fetchArtwork(storeID: m.storeID, completion: done)
        }
    }

    // MARK: rendering

    func setText(_ f: NSTextField, _ s: String) { if f.stringValue != s { f.stringValue = s; f.toolTip = s.isEmpty ? nil : s } }

    func refreshUI() {
        syncActivities()
        let b = body
        c.body = b
        if cardKind != .media && banner == nil && !hudActive && !dropping { lyricsRequested = false }
        c.lyricsVisible = lyricsVisible || (lyricsWidthTransition != nil && shape == .expanded && b == .media)
        c.lyricsPanelWidth = lyricsExtensionWidth
        c.mediaCardWidth = shape == .expanded && b == .media ? expandedCardWidth - 2 * earRadius(notchH + expandedExtraFor(.media)) : nil
        c.lyricsB.isEnabled = supportsLyrics
        let lyricsTint: NSColor = lyricsRequested ? artColor : .white
        if c.lyricsB.contentTintColor != lyricsTint { c.lyricsB.contentTintColor = lyricsTint }
        let lyricsLabel = lyricsRequested ? "가사 닫기" : "가사 보기"
        if c.lyricsB.accessibilityLabel() != lyricsLabel { c.lyricsB.setAccessibilityLabel(lyricsLabel) }
        let lyricsTip = supportsLyrics ? lyricsLabel : "Apple Music 재생 중에 사용할 수 있습니다"
        if c.lyricsB.toolTip != lyricsTip { c.lyricsB.toolTip = lyricsTip }
        c.lyricsPane.update(lyrics.state, version: lyrics.version, time: lyricsPlaybackTime, duration: media?.duration, advance: false)
        c.ending = b == .none && acts.isEmpty
        c.bandH = (shape == .expanded || (shape == .collapsed && atRest)) ? notchH : compactH

        c.transition(to: String(describing: cardKind) + String(describing: b))
        populate(c, bn: displayBanner, kind: cardKind)
        updateLockBorder()
        if let k = cardKind, let i = acts.firstIndex(of: k) {           // the wheel follows the shown activity (and a finger on it)
            view.dial.count = acts.count
            if Date().timeIntervalSince(lastScrollAt) > 0.6 {
                // the wheel only ever turns the short way round to the shown activity (it may have been spun several times)
                let n = CGFloat(acts.count)
                let near = CGFloat(i) + n * ((view.dial.position - CGFloat(i)) / n).rounded()
                dialPos = near; view.dial.set(near, animated: true)
            }
        }
        let dialOn = shape == .expanded && dialShown
        if dialOn != dialWasOn {
            dialWasOn = dialOn
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = dialOn ? 0.3 : 0.18; view.dial.animator().alphaValue = dialOn ? 1 : 0 }
        }

        // volume / brightness HUD (the main island only)
        if hudActive {
            let level = hudMuted ? 0 : hudValue
            let name: String
            switch hudKind {
            case .volume:
                name = (hudMuted || hudValue < 0.001) ? "speaker.slash.fill"
                     : hudValue < 0.34 ? "speaker.wave.1.fill" : hudValue < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            case .brightness:
                name = hudValue < 0.5 ? "sun.min.fill" : "sun.max.fill"
            }
            if name != c.hIconName {
                c.hIconName = name
                c.hIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 19, weight: .semibold))
            }
            c.hBar.setAccessibilityLabel(hudKind == .volume ? "볼륨" : "밝기")
            c.hBar.set(level, animated: true)
        }

        // alert
        setText(c.alertL, alertText ?? "")

        refreshSlots()
        let plan = makePlan()
        if plan != lastPlan { lastPlan = plan; placeSlots(plan) }
        c.needsLayout = true
        c.applyVisibility(expanded: shape == .expanded)
        if panel.isKeyWindow, shape == .expanded,
           !keyboardControls.contains(where: { $0 === panel.firstResponder }) {
            panel.makeFirstResponder(keyboardControls.first ?? view)
        }
    }

    /// Fills the card of one island (the main one or the second notch) with the data of the activity it shows.
    func populate(_ c: Content, bn: BannerKind?, kind: ActKind?) {
        // timer pieces
        setText(c.tTime, timer.text())
        setText(c.tLabel, timer.finished ? "타이머 완료" : (!timer.running && timer.started ? "일시정지됨" : (timer.mode == .stopwatch ? "스톱워치" : "남은 시간")))
        setSymbol(c.pauseB, timer.finished ? "arrow.clockwise" : (timer.running ? "pause.fill" : "play.fill"), 20)
        c.pauseB.setAccessibilityLabel(timer.finished ? "타이머 다시 시작" : (timer.running ? "타이머 일시정지" : "타이머 계속"))
        c.pauseB.toolTip = timer.finished ? "타이머 다시 시작" : (timer.running ? "타이머 일시정지" : "타이머 계속")

        // banner (charging / low battery / AirPods)
        if let bn = bn {
            switch bn {
            case .battery(let title, let level, let color):
                c.bannerIsAir = false
                setText(c.bTitle, title); setText(c.bPct, "\(level)%")
                c.bPct.textColor = color
                c.bGlyph.fraction = CGFloat(level) / 100; c.bGlyph.color = color
            case .airpods(let symbol, let level, let name, let connected):
                c.bannerIsAir = true
                if symbol != c.bannerSymbol {
                    c.bannerSymbol = symbol
                    c.bAir.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 21, weight: .regular))
                    c.bAir.contentTintColor = .white
                }
                setText(c.aTitle, name)
                setText(c.aState, connected ? "연결됨" : "연결 해제됨")
                c.aState.textColor = connected ? bannerGreen : NSColor(white: 1, alpha: 0.6)
                setText(c.aBattery, connected ? level.map { "\($0)%" } ?? "배터리 정보 없음" : "")
                c.bRing.fraction = CGFloat(level ?? 0) / 100
                c.bRing.isHidden = !connected || level == nil
            }
        }

        // file card
        if case .file(let u)? = kind, c.fileShown != u {
            c.fileShown = u
            c.fIcon.setFile(u)
            setText(c.fName, u.lastPathComponent)
            setText(c.fSub, fileSubtitle(u))
            c.fRevealB.isEnabled = FileManager.default.fileExists(atPath: u.path)
            c.fRevealB.alphaValue = c.fRevealB.isEnabled ? 1 : 0.35
        }

        // Balance the audio subscription even when the now-playing item disappears entirely.
        c.bodyEq.setPlaying(media?.playing == true && shape == .expanded && body == .media)
        // media pieces
        if let m = media {
            setText(c.titleL, m.title)
            setText(c.artistL, m.artist)
            c.art.setImage(artwork)
            let e = seekFraction.map { Double($0) * m.duration } ?? m.elapsedNow
            setText(c.elapsedL, mmss(e))
            setText(c.remainL, m.duration > 0 ? "-" + mmss(m.duration - e) : "")
            c.progress.fraction = m.duration > 0 ? CGFloat(e / m.duration) : 0
            c.progress.isHidden = m.duration <= 0
            setSymbol(c.playB, m.playing ? "pause.fill" : "play.fill", 30)
            c.bodyEq.color = artColor
        }
    }

    /// Updates what the small slot views show.
    func refreshSlots() {
        for (kind, item) in slotItems {
            if case .file(let url) = kind { (item.icon as? FilePreviewView)?.setFile(url) }
        }
        if let it = slotItem(.media), let art = it.icon as? ArtView, let eq = it.detail as? EqView {
            art.setImage(artwork); eq.color = artColor
            eq.setPlaying(media?.playing == true && usedViews.contains(where: { $0 === eq }))
        }
        if let it = slotItem(.timer), let l = it.detail as? NSTextField {
            setText(l, timer.text())
            if let ring = it.icon as? TimerRing {
                ring.countdown = timer.mode == .countdown
                ring.fraction = timer.mode == .countdown
                    ? CGFloat(timer.target > 0 ? max(0, timer.target - timer.elapsed) / timer.target : 0)     // shrinks
                    : CGFloat(timer.elapsed.truncatingRemainder(dividingBy: 60) / 60)                           // fills, a lap a minute
            }
        }
        if let it = slotItem(.charging), let l = it.detail as? NSTextField { setText(l, "\(chargeLevel)%") }
        if let it = slotItem(.lowBattery), let l = it.detail as? NSTextField {
            setText(l, "\(lowLevel)%")
            let col = lowLevel <= 10 ? bannerRed : accent
            l.textColor = col; (it.icon as? NSImageView)?.contentTintColor = col
        }
        if let it = slotItem(.airpods), let d = airInfo, let ring = it.detail as? RingView, let icon = it.icon as? NSImageView {
            ring.fraction = CGFloat(d.level ?? 0) / 100
            if icon.toolTip != d.symbol {
                icon.toolTip = d.symbol
                icon.image = NSImage(systemSymbolName: d.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
            }
        }
    }

    func fade(_ v: NSView, to a: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = a > 0 ? 0.28 : 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.animator().alphaValue = a
        }
    }

    /// Hands the slot views to the windows that now show them; views that are no longer shown fade out.
    func placeSlots(_ plan: Plan) {
        var now: [NSView] = []
        func use(_ v: NSView, in host: NSView) {
            now.append(v)
            if v.superview !== host { v.removeFromSuperview(); host.addSubview(v); v.alphaValue = 0 }
            if v.alphaValue < 1 { fade(v, to: 1) }
        }
        if let lk = plan.left, let it = slotItem(lk) {
            // a single activity: icon on the left, detail on the right. Several: the compact view (icon, or % for charging)
            let v = plan.rightDetail ? (view: it.icon, size: CGSize(width: 24, height: 24)) : slotView(lk)
            c.leftView = v.view; c.leftSize = v.size
            use(v.view, in: c)
        } else { c.leftView = nil }
        if let rk = plan.right, let it = slotItem(rk) {
            let v = plan.rightDetail ? (view: it.detail, size: it.detailSize) : slotView(rk)
            c.rightView = v.view; c.rightSize = v.size
            use(v.view, in: c)
        } else { c.rightView = nil }
        let pitems = plan.row.compactMap { slotItem($0) }
        for it in pitems { use(it.icon, in: rowView); use(it.detail, in: rowView) }
        let wasHidden = rowView.isHidden
        rowView.items = pitems
        rowView.isHidden = pitems.isEmpty
        if wasHidden && !pitems.isEmpty {
            rowView.alphaValue = 0
            fade(rowView, to: 1)
        }
        c.needsLayout = true
        let nowIDs = Set(now.map { ObjectIdentifier($0) })
        let stale = usedViews.filter { !nowIDs.contains(ObjectIdentifier($0)) }
        for v in stale { fade(v, to: 0) }
        usedViews = now
        if !stale.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let s = self else { return }
                let keep = Set(s.usedViews.map { ObjectIdentifier($0) })
                for v in stale where !keep.contains(ObjectIdentifier(v)) { v.removeFromSuperview() }
            }
        }
    }

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
        if var transition = lyricsWidthTransition {
            if shape != .expanded || body != .media { lyricsWidthTransition = nil; mainP.w.vel = 0 }
            else if abs(transition.to - Double(r.width)) > 0.01 {      // hover / press swell moved the target: follow it, do not cancel
                transition.to = Double(r.width); lyricsWidthTransition = transition
            }
        }
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
        var completedLyricsTransition = false
        for p in [mainP!] where p.active || p.visible {
            let isMain = p === mainP
            let k: CGFloat = isMain ? stiffness : 300, cd: CGFloat = isMain ? damping : 28
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { p.snap() }
            let widthTransition = isMain ? lyricsWidthTransition : nil
            for _ in 0..<steps {
                p.x.step(h, k, cd)
                if widthTransition == nil { p.w.step(h, k, cd) }
                p.h.step(h, k, cd); p.ty.step(h, k, cd); p.m.step(h, k, cd)
            }
            if let transition = widthTransition {
                let now = hardwareSeconds()
                p.w.cur = CGFloat(transition.value(at: now)); p.w.vel = 0
                if transition.finished(at: now) {
                    p.w.jump(CGFloat(transition.to)); lyricsWidthTransition = nil
                    completedLyricsTransition = true
                }
            }
            if isMain {
                // Momentum from an interrupted move must never uncover the hardware notch.
                if p.x.cur > notchLeft { p.x.cur = notchLeft; if p.x.vel > 0 { p.x.vel = 0 } }
                if p.x.cur + p.w.cur < notchRight { p.w.cur = notchRight - p.x.cur; if p.w.vel < 0 { p.w.vel = 0 } }
                if lyricsVisible && p.x.cur + p.w.cur > screen.frame.maxX - lyricsEdgeMargin {
                    p.w.cur = max(notchW, screen.frame.maxX - lyricsEdgeMargin - p.x.cur)
                    if p.w.vel > 0 { p.w.vel = 0 }
                }
                if p.h.cur < notchH { p.h.cur = notchH; if p.h.vel < 0 { p.h.vel = 0 } }
            }
            if p.settled && lyricsWidthTransition == nil { p.snap() } else { allSettled = false }
            if !p.active && p.settled && p.w.cur < 1.5 {          // shrunk away: take the window off screen
                p.panel.orderOut(nil); p.shadow?.orderOut(nil); p.visible = false; p.w.jump(0)
                continue
            }
            if !isMain { p.panel.alphaValue = p.fullW > 0 ? min(1, max(0, p.w.cur / p.fullW)) : 0 }
            let margin = max(p.m.cur, 0)
            let f = NSRect(x: p.x.cur.rounded(), y: screen.frame.maxY - p.ty.cur - p.h.cur, width: max(p.w.cur, 1), height: max(p.h.cur, 1))   // the island
            if isMain {
                let base = expandedBase
                let k = base.w > 0 ? max(1, min(1.12, (p.w.cur - base.ext) / base.w)) : 1
                view.refHeight = shape == .expanded ? p.h.cur / k : 0
                view.swellInset = shape == .expanded ? max(-12, min(12, (screen.frame.midX - base.w / 2) - f.minX)) : 0     // pin the content to its resting spot (absolute), whatever the island does round it
            }
            if isMain { view.bottomInset = margin; if lockIsland != f { lockIsland = f; if locked { updateLockBorder() } } }
            p.panel.setFrame(NSRect(x: f.minX, y: f.minY - margin, width: f.width, height: f.height + margin), display: true)
            if let sh = p.shadow {
                sh.setFrame(f.insetBy(dx: -ShadowView.pad, dy: -ShadowView.pad), display: true)
                sh.alphaValue = p.panel.alphaValue
            }
        }
        if completedLyricsTransition { refreshUI() }
        atRest = mainP.settled && lyricsWidthTransition == nil
        if allSettled { l.isPaused = true }
    }
}

