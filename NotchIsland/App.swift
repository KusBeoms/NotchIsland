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
    var sensorRecognizer = SensorGestureRecognizer()                 // light-sensor cover -> tap / hold / double tap (see SensorGesture.swift)
    var lyricsHoldFired = false          // this press already toggled the lyrics: its release must not also close the island

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
    var swellSuppressed = false          // after pinning: stay small until the pointer has left
    var lockBorder: NSPanel?; var lockBorderLayer: CAShapeLayer?; var lockBorderTarget: CGFloat = 0
    var lockBorderGeometry: LockBorderGeometry?
    var playTapGeneration = 0           // bumped by every play / pause tap: delayed confirmations of an older tap are ignored
    var locked = false                 // pinned by tapping the expanded island: ignores outside clicks / Esc / sensor until tapped again
    var hoverUntil = Date.distantPast
    var missionControl = false         // Mission Control is up: the island folds away (even when locked) and comes back after
    var windowsHidden = false          // the island's windows are off screen (mirroring or a locked screen)
    var mirrorCallbackRegistered = false
    var hoverLeftAt: Date?
    var tLockCheck = 0.0
    var lockProbe: () -> Bool = App.sessionScreenLocked                     // tests replace it
    var screenLocked = false           // the Mac's screen is locked: no peek, sensor gestures or new alerts meanwhile
    var hoverEnteredAt: Date?          // when the pointer reached the island (the peek waits `HoverDwell.dwell`)
    var islandSuppressed: Bool { mirrorHidden || screenLocked }
    var mirrorHidden = false           // the built-in display is mirrored: the island's windows are off screen (see Mirroring.swift)
    var mirrorInfo: () -> [DisplayMirrorInfo]? = MirrorPolicy.current        // tests replace it
    var lockShown: Bool { locked && !missionControl && !mirrorHidden }
    var lux = -1.0
    var media: Media? {
        didSet {
            if oldValue?.trackID != media?.trackID { cancelPendingSeek() }
            lyrics.select(lyricsTrack)
            if !supportsLyrics { lyricsRequested = false }
        }
    }
    var lyrics = LyricsController()
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
    let settingsWindow = SettingsWindowController()
    let updater = Updater()                            // new releases on GitHub (App+Update.swift)
    let privacyMonitor = PrivacyMonitor()
    let transferMonitor = TransferMonitor()            // downloads and copies other apps publish progress for
    let calendarMonitor = CalendarMonitor()
    var calendarEvents: [CalendarEvent] = []           // today's events; the one to show is chosen by CalendarRules.featured
    var calendarAlerted = Set<String>()                // events that already got their "in 5 minutes" alert
    var privacy = PrivacyState()                       // who is using the microphone / camera right now
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
    /// Covering the light sensor with a finger makes macOS dim the screen. A sudden dark is a touch, so macOS's automatic
    /// brightness is paused for it; real darkness (a slow fade is never latched, or a long cover) hands control back.
    var autoBrightnessHeld = false
    var lightBase = -1.0                 // slow average of the light: a fade moves it along, a sudden drop does not
    var dropSince: Date?                 // when the light fell away suddenly (nil = no drop in progress)
    var recoveredSince: Date?            // light back near its old level (debounces a flickering cover)
    var lastBrightness: Float?
    var lastBrightnessRead = Date.distantPast
    static let realDarkAfter: TimeInterval = 5
    static let autoBrightnessHeldKey = "autoBrightnessHeld"
    var darkLatched = false          // dark state with hysteresis: set below threshold, cleared above 1.2x

    var notchW: CGFloat {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return screen.frame.width - l.width - r.width
        }
        return 180
    }
    var notchH: CGFloat { max(screen.safeAreaInsets.top, 32) }

    // state of App+Activities.swift
    var dialWasOn = false
    var holdH: CGFloat = 0                              // while scrolling the card never gets lower, so the pointer stays on the dial
    var lastScrollAt = Date.distantPast
    var dialPos: CGFloat = 0                            // where the fingers have turned the wheel, in activities (continuous)
    var dialLastTick = 0
    var lastDialHaptic = Date.distantPast
    var dialSettle: Timer?
    let iconWing: CGFloat = 46                                       // space beside the notch for one icon

    // state of App+Seeking.swift
    var seekFraction: CGFloat?                  // where the user has put the playhead, until it is committed
    var seekTrack: Media.TrackID?
    var scrubbingTrack: Media.TrackID?           // keep the original drag target until mouse-up, even if the track changes
    var playHoldUntil = Date.distantPast        // right after a play / pause tap the poll may still report the old state
    var seekHoldUntil = Date.distantPast        // right after a seek the poll still reports the old position: ignore it
    var seekTimer: Timer?

    // state of App+Events.swift
    var volDev = AudioObjectID(0)
    var volBlock: AudioObjectPropertyListenerBlock?
    var batteryRL: CFRunLoopSource?
    var musicDebounce: Timer?
    var lastOutDev: AudioObjectID = 0
    var outDebounce: Timer?

    // state of App+Step.swift
    var stepTimer: Timer?, stepBusy = false, stepDeep = false
    var sensorWasOn = false, sensorDt = 0.0, lastSensorSample = 0.0, lastSensorReading = 0.0
    var sensorEnabled = true, tSensorConfig = 0.0, sensorActiveAt = 0.0     // sensorActiveAt: CFAbsoluteTime of the last finger-like reading
    var tTimerSave = 0.0, savedTimer: TimerSnapshot?
    /// Seconds since the user last touched the keyboard, mouse or trackpad (anywhere in the session); tests replace it.
    var inputIdleSeconds: () -> TimeInterval = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
    var deferredAlerts: [(since: Date, run: () -> Bool)] = []       // see whenQuiet
    var tAppearance = 0.0, tFiles = 0.0, tVolume = 0.0, tBattery = 0.0, tMusic = 0.0, tAirPods = 0.0, tCalendar = 0.0, tMission = 0.0

    // state of App+Polling.swift
    var artRetryAt: [String: Date] = [:], artTries: [String: Int] = [:]


    func applicationDidFinishLaunching(_ n: Notification) {
        releaseAutoBrightness()                      // a previous run that died while holding it
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.releaseAutoBrightness(); self?.saveTimerIfChanged(); exit(0) }
            src.resume(); signalSources.append(src)
        }
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
        c.lyricsPane.onReload = { [weak self] in
            guard let self else { return }
            self.lyrics.requestNow(force: true)
            self.lyrics.refreshIfNeeded()
        }
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
        restoreTimer()
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
            v.onPressMoved = { [weak self] in self?.pressMoved() }
            v.onDragFinished = { [weak self] u, taken in if taken { self?.fileRemove(u) } }   // taken out: it leaves the pocket
        }
        c.fRevealB.target = self; c.fRevealB.action = #selector(revealFileTapped)
        c.fRemoveB.target = self; c.fRemoveB.action = #selector(removeFileTapped)
        c.hBar.onChange = { [weak self] v in self?.hudDragged(v) }
        c.progress.onScrub = { [weak self] f, final in self?.scrubbed(f, final: final) }
        view.dial.onDrag = { [weak self] dx, ph in self?.dialDragged(dx, ph) }
        view.onOpenSource = { [weak self] in    // on the lyrics the cover is a play / pause button; otherwise it opens the music app
            guard let s = self else { return }
            if s.lyricsVisible { s.playPauseTapped() } else { s.openSourceApp() }
        }
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
        privacyMonitor.onChange = { [weak self] state in
            self?.privacy = state; self?.refreshUI(); self?.applyShape()
        }
        applyPrivacySetting()
        calendarMonitor.onChange = { [weak self] events in
            self?.calendarEvents = events
            self?.calendarAlerted.formIntersection(events.map(\.id))         // forget events that are gone
            self?.pollCalendar()
        }
        applyCalendarSetting()
        transferMonitor.onChange = { [weak self] in self?.refreshUI(); self?.applyShape() }
        transferMonitor.onFinished = { [weak self] t, ok in
            guard ok, Settings.downloadsEnabled else { return }              // stopped half way: no "done"
            self?.showAlert("\(TransferRules.completionLabel(t.operation)) · \(t.name)", seconds: 4)
        }
        if demoTransfer { transferMonitor.startDemo() } else { applyTransferSetting() }
        if demoSettings { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.settingsWindow.show() } }
        settingsWindow.caption = { key in key == Settings.Key.calendar ? CalendarMonitor.statusCaption : nil }
        setupUpdater()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: Settings.changed, object: nil)
        watchOutputDevice()
        watchSleep()
        watchVolume()
        watchBattery()
        watchMusicApps()
        watchScreens()
        watchMirroring()
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
}
