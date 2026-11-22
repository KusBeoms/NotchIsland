import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Rendering: refreshUI, filling cards, the generic info card.

extension App {
    /// What the generic info card shows for an activity.
    struct InfoCard {
        var symbol: String
        var tint: NSColor
        var title: String
        var sub = ""
        var trail = ""
        var fraction: Double? = nil      // the bar: 0...1, or nil for "total unknown"
        var showsBar = false
    }
    func infoCard(for kind: ActKind?) -> InfoCard? {
        switch kind {
        case .privacy?: return InfoCard(symbol: privacySymbol, tint: privacyColor, title: privacy.title, sub: privacy.subtitle)
        case .transfer(let id)?:
            guard let t = transferMonitor.transfers.first(where: { $0.id == id }) else { return nil }
            return InfoCard(symbol: TransferRules.symbol(t.operation), tint: transferTint, title: t.name,
                            sub: TransferRules.subtitle(label: TransferRules.operationLabel(t.operation), bytesPerSecond: t.bytesPerSecond, remaining: t.remaining),
                            trail: TransferRules.percentText(t.fraction), fraction: t.fraction, showsBar: true)
        case .calendar?:
            guard let e = featuredEvent else { return nil }
            return InfoCard(symbol: "calendar", tint: calendarTint, title: e.title, sub: CalendarRules.subtitle(e),
                            trail: CalendarRules.trail(e, now: Date()))
        default: return nil
        }
    }

    // MARK: rendering

    func setText(_ f: NSTextField, _ s: String) { if f.stringValue != s { f.stringValue = s; f.toolTip = s.isEmpty ? nil : s } }

    func refreshUI() {
        syncActivities()
        let b = body
        c.body = b
        if !acts.contains(.media) { lyricsRequested = false }      // switching to another activity keeps the lyrics for when the music card returns
        c.lyricsVisible = lyricsVisible
        c.mediaCardWidth = shape == .expanded && b == .media ? expandedCardWidth - 2 * earRadius(notchH + expandedExtraFor(.media)) : nil
        c.lyricsB.isEnabled = supportsLyrics
        let artTip = lyricsVisible ? media.map { m in [m.title, m.artist].filter { !$0.isEmpty }.joined(separator: " — ") + " · 탭하면 재생 / 일시정지" } : nil
        if c.art.toolTip != artTip { c.art.toolTip = artTip; c.art.setAccessibilityLabel(artTip ?? "") }
        let lyricsTint: NSColor = lyricsRequested ? artColor : .white
        if c.lyricsB.contentTintColor != lyricsTint { c.lyricsB.contentTintColor = lyricsTint }
        let lyricsLabel = lyricsRequested ? "가사 닫기" : "가사 보기"
        if c.lyricsB.accessibilityLabel() != lyricsLabel { c.lyricsB.setAccessibilityLabel(lyricsLabel) }
        let lyricsTip = supportsLyrics ? lyricsLabel : "Apple Music 재생 중에 사용할 수 있습니다"
        if c.lyricsB.toolTip != lyricsTip { c.lyricsB.toolTip = lyricsTip }
        c.lyricsPane.update(lyrics.state, version: lyrics.version, time: lyricsPlaybackTime, duration: media?.duration, playing: media?.playing ?? false, advance: false)
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
        if let set = timer.pomodoro {
            setText(c.tLabel, timer.running ? set.label : "\(set.label) · 일시정지")
            c.tLabel.textColor = set.isBreak ? bannerGreen : accent
        } else {
            setText(c.tLabel, timer.finished ? "타이머 완료" : (!timer.running && timer.started ? "일시정지됨" : (timer.mode == .stopwatch ? "스톱워치" : "남은 시간")))
            c.tLabel.textColor = accent
        }
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
            c.setRevealEnabled(FileManager.default.fileExists(atPath: u.path))
        }

        // info card (microphone / camera, ...)
        if let card = infoCard(for: kind) {
            if card.symbol != c.iIconName {
                c.iIconName = card.symbol
                c.iIcon.image = NSImage(systemSymbolName: card.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
            }
            c.iIcon.contentTintColor = card.tint
            setText(c.iTitle, card.title); setText(c.iSub, card.sub); setText(c.iTrail, card.trail)
            c.iTrail.textColor = card.tint
            c.infoShowsBar = card.showsBar
            c.iBar.color = card.tint
            c.iBar.fraction = card.fraction
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
}
