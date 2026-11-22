import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Menu bar item and its menu actions, settings entry points.

extension App {
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
            let heading = timer.pomodoro.map { "포모도로 \($0.label) " } ?? (timer.mode == .stopwatch ? "스톱워치 " : "타이머 ")
            menu.addItem(withTitle: heading + timer.text(), action: nil, keyEquivalent: "").isEnabled = false
            add(timer.finished ? "다시 시작" : (timer.running ? "일시정지" : "계속"), #selector(menuToggleTimer))
            add("취소", #selector(menuCancelTimer))
        } else {
            add("스톱워치 시작", #selector(menuStopwatch))
            let pomodoro = Settings.pomodoro
            add("포모도로 시작 (\(pomodoro.work)/\(pomodoro.rest))", #selector(menuPomodoro))
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
        add("설정…", #selector(menuSettings), key: ",")
        menu.addItem(updateMenuItem())
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "NotchIsland 종료", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
    }

    func activityName(_ kind: ActKind) -> String {
        switch kind {
        case .media: return "미디어: \(TextClip.tail(media?.title ?? "재생 중", limit: 40))"
        case .timer:
            if let set = timer.pomodoro { return "포모도로 \(set.label): \(timer.text())" }
            return timer.finished ? "타이머 완료" : "타이머: \(timer.text())"
        case .charging: return "충전 중"
        case .lowBattery: return "배터리 부족"
        case .airpods: return "AirPods"
        case .privacy: return privacy.subtitle.isEmpty ? privacy.title : "\(privacy.title): \(privacy.subtitle)"
        case .transfer(let id):
            guard let t = transferMonitor.transfers.first(where: { $0.id == id }) else { return "전송" }
            return "\(TransferRules.operationLabel(t.operation)): \(TextClip.middle(t.name, limit: 36)) \(TransferRules.percentText(t.fraction))"
        case .calendar:
            guard let e = featuredEvent else { return "일정" }
            return "일정: \(TextClip.tail(e.title, limit: 40)) (\(CalendarRules.trail(e, now: Date())))"
        case .file(let url): return "파일: \(TextClip.middle(url.lastPathComponent, limit: 36))"
        }
    }

    @objc func menuToggleIsland() {
        guard !islandSuppressed else { return }
        if pinned || hudActive {
            guard dismissIsland(clearHUD: true) else { return }      // locked: Cmd+. does not close it
            selected = nil
            releaseKeyboardFocus()
        } else if let kind = acts.first { selected = kind; pinned = true }
        else { showAlert("실행 중인 활동이 없습니다", seconds: 4) }
        refreshUI(); applyShape()
        if pinned { focusIsland() }
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
    @objc func menuSettings() { settingsWindow.show() }

    /// Starts or stops what a setting switched on or off. Called at launch and after every change in the settings window.
    @objc func settingsChanged() {
        applyMirroring()                              // "hide while mirroring" takes effect at once
        applyPrivacySetting()
        applyCalendarSetting()
        applyTransferSetting()
        applyUpdateSetting()
        refreshUI(); applyShape()
    }
    func applyPrivacySetting() {
        if let demo = demoPrivacy { privacy = demo; return }                      // --demo-privacy: a fixed fake state
        if Settings.privacyEnabled && ProcessInfo.processInfo.environment["NI_NOPRIVACY"] == nil {
            privacyMonitor.start()
        } else {
            privacyMonitor.stop(); privacy = PrivacyState()
        }
    }
    func applyCalendarSetting() {
        if demoCalendar { calendarEvents = [Self.demoCalendarEvent()]; return }       // --demo-calendar: a meeting in 10 minutes
        if Settings.calendarEnabled && ProcessInfo.processInfo.environment["NI_NOCALENDAR"] == nil {
            calendarMonitor.start()
        } else {
            calendarMonitor.stop(); calendarEvents = []
        }
    }
    func applyTransferSetting() {
        if demoTransfer { return }                                                  // --demo-transfer starts its own fake download
        if Settings.downloadsEnabled && ProcessInfo.processInfo.environment["NI_NODOWNLOADS"] == nil {
            transferMonitor.start()
        } else {
            transferMonitor.stop()
        }
    }
    static func demoCalendarEvent() -> CalendarEvent {
        let start = Date().addingTimeInterval(10 * 60)
        return CalendarEvent(id: "demo", title: "디자인 리뷰", location: "회의실 3", start: start, end: start.addingTimeInterval(3600))
    }

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
    @objc func menuPomodoro() { timer.startPomodoro(Settings.pomodoro); refreshUI() }
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
}
