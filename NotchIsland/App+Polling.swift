import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Polled sources: battery, AirPods, music, artwork.

extension App {
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

    /// The calendar event the island shows right now, if any (see CalendarRules.featured).
    var featuredEvent: CalendarEvent? { CalendarRules.featured(calendarEvents, now: Date()) }

    /// Time passes without any event arriving: an event turns into an activity 30 minutes before it starts, gets one alert
    /// 5 minutes before, and goes away when it is over. Called from the step loop and whenever the events change.
    func pollCalendar() {
        let now = Date()
        if Settings.calendarEnabled, let e = featuredEvent, CalendarRules.shouldAlert(e, now: now, alerted: calendarAlerted) {
            calendarAlerted.insert(e.id)
            let id = e.id
            whenQuiet { [weak self] in                 // the wording ("in 5 minutes") is made when it is shown, from the event as it is then
                guard let s = self, let e = s.featuredEvent, e.id == id, CalendarRules.alertStillUseful(e, now: Date()) else { return false }
                s.showAlert(CalendarRules.alertText(e, now: Date()), seconds: 5); return true
            }
        }
        // an idle, empty island does not redraw by itself: refresh when the activity appears or disappears
        if isActive(.calendar) != actOrder.contains(.calendar) { refreshUI(); applyShape() }
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
}
