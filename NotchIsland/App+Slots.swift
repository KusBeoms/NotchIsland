import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - The small slot views of each activity (icons / details beside the notch).

extension App {
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
        if case .transfer = k {                                 // a progress ring, and the percentage beside it
            let ring = RingView(); ring.color = transferTint
            let it = SlotItem(icon: ring, detail: makeLabel(13, .semibold, transferTint, mono: true, align: .right), detailSize: CGSize(width: 46, height: 18))
            slotItems[k] = it
            return it
        }
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
        let dot = NSView(); dot.wantsLayer = true; dot.layer?.cornerRadius = 5; dot.layer?.backgroundColor = accent.cgColor
        slotItems[.calendar] = SlotItem(icon: symbolView("calendar", 15, calendarTint),
                                        detail: makeLabel(13, .semibold, calendarTint, mono: true, align: .right), detailSize: CGSize(width: 46, height: 18))
        slotItems[.privacy] = SlotItem(icon: symbolView("mic.fill", 15, accent), detail: dot, detailSize: CGSize(width: 10, height: 10))
    }

    /// Camera in use is green, microphone orange (like the system's own indicators); both -> the camera's colour.
    var privacyColor: NSColor { privacy.camera ? bannerGreen : accent }
    var privacySymbol: String { privacy.camera ? "video.fill" : "mic.fill" }
    var calendarTint: NSColor { NSColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1) }
    var transferTint: NSColor { NSColor(red: 0.3, green: 0.75, blue: 1.0, alpha: 1) }

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
                ring.pomodoro = timer.pomodoro?.phase
                ring.fraction = timer.mode == .countdown
                    ? CGFloat(timer.target > 0 ? max(0, timer.target - timer.elapsed) / timer.target : 0)     // shrinks
                    : CGFloat(timer.elapsed.truncatingRemainder(dividingBy: 60) / 60)                           // fills, a lap a minute
            }
        }
        for t in transferMonitor.transfers {
            guard let it = slotItems[.transfer(t.id)], let ring = it.icon as? RingView, let l = it.detail as? NSTextField else { continue }
            ring.fraction = CGFloat(t.fraction ?? 0.25)                    // total unknown: a quarter ring instead of a percentage
            setText(l, t.fraction == nil ? "…" : TransferRules.percentText(t.fraction))
        }
        if let it = slotItem(.calendar), let l = it.detail as? NSTextField, let e = featuredEvent { setText(l, CalendarRules.trail(e, now: Date())) }
        if let it = slotItem(.privacy), let icon = it.icon as? NSImageView {
            if icon.identifier?.rawValue != privacySymbol {
                icon.identifier = NSUserInterfaceItemIdentifier(privacySymbol)       // remembers which glyph is set
                icon.image = NSImage(systemSymbolName: privacySymbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
            }
            icon.contentTintColor = privacyColor
            it.detail.layer?.backgroundColor = privacyColor.cgColor
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
}
