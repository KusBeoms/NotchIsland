import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Which activities are running, which card shows, and the dial that switches between them.

extension App {
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
        case .privacy: return Settings.privacyEnabled && privacy.isActive
        case .calendar: return Settings.calendarEnabled && featuredEvent != nil
        case .transfer(let id): return Settings.downloadsEnabled && transferMonitor.transfers.contains { $0.id == id }
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
        for t in transferMonitor.transfers where Settings.downloadsEnabled && !actOrder.contains(.transfer(t.id)) { actOrder.append(.transfer(t.id)) }
        func gone(_ k: ActKind) -> Bool {
            switch k {
            case .file(let u): return !files.contains(u)
            case .transfer: return !isActive(k)
            default: return false
            }
        }
        for k in actOrder where gone(k) { if case .transfer = k { slotItems.removeValue(forKey: k) } }     // a transfer's views die with it
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
        case .privacy, .calendar, .transfer: return .info
        case .file: return .file
        }
    }

    /// The dial is shown along the bottom of an open activity card when there is more than one activity to choose from.
    var dialShown: Bool { !hudActive && !dropping && banner == nil && alertText == nil && acts.count >= 2 && cardKind != nil }
    var dialMargin: CGFloat { (shape == .expanded && dialShown) ? 62 : 0 }       // room under the island for the dial's ticks
    var scrollHolding: Bool { dialShown && shape == .expanded && Date().timeIntervalSince(lastScrollAt) < 1.0 }

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
        if lyricsVisible, c.lyricsPane.frame.contains(c.convert(e.locationInWindow, from: nil)) { return }
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
        case .privacy?, .calendar?, .transfer?: return .info
        case nil: return .none
        }
    }
    var hudActive: Bool { Date() < hudUntil }
    var liveActivity: Bool { hudActive || banner != nil || alertText != nil || !acts.isEmpty }
    /// Space beside the notch when a single activity shows its icon on the left and its detail on the right.
    func wingWidth(_ k: ActKind) -> CGFloat {
        switch k { case .timer, .calendar, .transfer: return 66; case .charging: return 58; case .lowBattery: return 62; case .airpods: return 44; default: return 50 }
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
        case .info:   return 66
        case .banner, .hud: return 0
        default:      return 38
        }
    }
}
