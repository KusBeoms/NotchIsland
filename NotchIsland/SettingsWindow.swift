import AppKit
import ServiceManagement

// MARK: - Settings window

/// One small window with every setting. It is rebuilt each time it opens, so it always shows the stored values.
/// The app is an accessory (no Dock icon, no main menu): open it from the status item menu with `show()`.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var valueLabels: [String: NSTextField] = [:]
    /// A caption shown under a checkbox, keyed by the setting's key (e.g. "calendar access was denied"). nil = none.
    var caption: (String) -> String? = { _ in nil }
    /// The update line under the auto-update checkbox, and what the "check now" button does.
    var updateStatus: () -> String = { "" }
    var onCheckUpdate: () -> Void = {}
    private var updateStatusLabel: NSTextField?

    private static let toggles: [(key: String, title: String)] = [
        (Settings.Key.calendar, "캘린더의 다음 일정 표시"),
        (Settings.Key.privacy, "마이크·카메라 사용 중 표시"),
        (Settings.Key.downloads, "다운로드 진행률 표시"),
        (Settings.Key.zeroVolume, "출력 장치를 바꾸면 볼륨을 0으로"),
        (Settings.Key.hideMirroring, "화면 미러링 중에는 섬 숨기기"),
        (Settings.Key.muteMirroring, "화면 미러링 중에는 알림음 끄기"),
    ]
    private static let steppers: [(key: String, title: String)] = [
        (Settings.Key.pomodoroWork, "집중"),
        (Settings.Key.pomodoroBreak, "휴식"),
        (Settings.Key.pomodoroLongBreak, "긴 휴식"),
        (Settings.Key.pomodoroLongEvery, "긴 휴식 주기"),
    ]

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        let w = window ?? makeWindow()
        let firstTime = window == nil
        window = w
        w.contentView = makeContent()
        let fit = w.contentView?.fittingSize ?? NSSize(width: 420, height: 400)
        w.setContentSize(NSSize(width: fit.width + 24, height: fit.height))          // the grid of popups needs its right margin too
        if firstTime { w.center() }
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "NotchIsland 설정"
        w.isReleasedWhenClosed = false
        w.delegate = self
        return w
    }

    // MARK: content

    private func makeContent() -> NSView {
        valueLabels = [:]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 22, right: 24)

        stack.addArrangedSubview(header("표시할 활동"))
        for t in Self.toggles {
            let box = NSButton(checkboxWithTitle: t.title, target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(t.key)
            box.state = Settings.bool(t.key) ? .on : .off
            stack.addArrangedSubview(box)
            if let text = caption(t.key) { stack.addArrangedSubview(note(text, indent: true)) }
        }

        stack.addArrangedSubview(space(6))
        stack.addArrangedSubview(header("포모도로"))
        for s in Self.steppers {
            let d = Settings.intDefaults[s.key]!
            let stepper = NSStepper()
            stepper.minValue = Double(d.range.lowerBound); stepper.maxValue = Double(d.range.upperBound)
            stepper.increment = 1; stepper.valueWraps = false
            stepper.integerValue = Settings.int(s.key)
            stepper.identifier = NSUserInterfaceItemIdentifier(s.key)
            stepper.target = self; stepper.action = #selector(stepped(_:))
            let title = NSTextField(labelWithString: s.title)
            title.widthAnchor.constraint(equalToConstant: 96).isActive = true
            let value = NSTextField(labelWithString: valueText(s.key, Settings.int(s.key)))
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 56).isActive = true
            valueLabels[s.key] = value
            let row = NSStackView(views: [title, value, stepper])
            row.orientation = .horizontal; row.spacing = 8
            stack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(space(6))
        stack.addArrangedSubview(header("센서 제스처 (조도 센서를 손가락으로 덮을 때)"))
        stack.addArrangedSubview(gestureGrid())
        stack.addArrangedSubview(note("'두 번 덮기'에 동작을 지정하면, 같은 곳의 '짧게 덮기' 동작은 두 번째 덮기를 기다리느라 0.35초 늦게 실행됩니다.\n기본값은 원래 동작과 같습니다: 닫혀 있을 때 길게 덮기 = 열기, 음악 카드에서 짧게 = 닫기·길게 = 가사, 다른 카드에서 짧게 = 닫기."))

        stack.addArrangedSubview(space(6))
        stack.addArrangedSubview(header("업데이트"))
        let auto = NSButton(checkboxWithTitle: "새 버전이 나오면 자동으로 업데이트", target: self, action: #selector(toggled(_:)))
        auto.identifier = NSUserInterfaceItemIdentifier(Settings.Key.autoUpdate)
        auto.state = Settings.autoUpdateEnabled ? .on : .off
        stack.addArrangedSubview(auto)
        let status = NSTextField(labelWithString: updateStatus())
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.widthAnchor.constraint(equalToConstant: 250).isActive = true
        updateStatusLabel = status
        let check = NSButton(title: "지금 확인", target: self, action: #selector(checkUpdateTapped))
        check.controlSize = .small
        let row = NSStackView(views: [status, check])
        row.orientation = .horizontal; row.spacing = 8
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(note("켜 두면 새 버전을 내려받아, 앱이 쉬는 동안 저절로 다시 시작하며 적용합니다(타이머·스톱워치가 초기화될 때까지 미룹니다).\n꺼 두면 '지금 확인'으로 내려받은 뒤 메뉴에서 직접 다시 시작해야 합니다.\n임시 서명으로 설치한 앱은 서명을 확인할 수 없어 스스로 설치하지 않고, 릴리스 페이지로만 안내합니다."))

        stack.addArrangedSubview(space(6))
        stack.addArrangedSubview(header("일반"))
        let login = NSButton(checkboxWithTitle: "로그인할 때 자동으로 실행", target: self, action: #selector(loginToggled(_:)))
        let look = LoginItemPolicy.checkbox(status: Self.loginStatus, agentPlistExists: Self.installScriptAgentExists)
        login.state = look.on ? .on : .off
        login.isEnabled = look.enabled
        stack.addArrangedSubview(login)
        if let text = look.note { stack.addArrangedSubview(note(text, indent: true)) }
        let quit = NSButton(title: "NotchIsland 종료", target: self, action: #selector(quitTapped))
        quit.controlSize = .small
        stack.addArrangedSubview(quit)

        stack.frame.size = stack.fittingSize
        return stack
    }

    /// Called when the updater's state changes while the window is open.
    func refreshUpdateStatus() { updateStatusLabel?.stringValue = updateStatus() }

    private func gestureGrid() -> NSGridView {
        let map = SensorGestureMap(Settings.sensorGestureMap)
        func small(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
            return l
        }
        var rows: [[NSView]] = [[NSView()] + SensorContext.allCases.map { small($0.title) }]
        for g in SensorGesture.allCases {
            var row: [NSView] = [NSTextField(labelWithString: g.title)]
            for c in SensorContext.allCases {
                let allowed = SensorGestureMap.allowedActions(c)
                let pop = NSPopUpButton(frame: .zero, pullsDown: false)
                pop.controlSize = .small
                pop.font = .systemFont(ofSize: 11)
                for a in allowed { pop.addItem(withTitle: a.title); pop.lastItem?.representedObject = a.rawValue }
                pop.selectItem(at: allowed.firstIndex(of: map.action(c, g)) ?? 0)
                pop.identifier = NSUserInterfaceItemIdentifier("\(c.rawValue).\(g.rawValue)")
                pop.target = self; pop.action = #selector(gestureChanged(_:))
                pop.widthAnchor.constraint(equalToConstant: 132).isActive = true
                row.append(pop)
            }
            rows.append(row)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6; grid.columnSpacing = 10
        return grid
    }

    private func valueText(_ key: String, _ value: Int) -> String {
        key == Settings.Key.pomodoroLongEvery ? "\(value)회마다" : "\(value)분"
    }

    private func header(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }
    private func note(_ text: String, indent: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 340
        if indent { l.setContentHuggingPriority(.defaultHigh, for: .horizontal) }
        return l
    }
    private func space(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    // MARK: actions

    /// Starts the app at login through the system's own login-item list (visible and removable in System Settings).
    @objc private func loginToggled(_ sender: NSButton) {
        func fail(_ detail: String) {
            sender.state = LoginItemPolicy.registered(Self.loginStatus) ? .on : .off          // show what is really set
            let alert = NSAlert()
            alert.messageText = "로그인 항목을 바꾸지 못했습니다"
            alert.informativeText = detail
            alert.runModal()
        }
        if sender.state == .on {
            do { try SMAppService.mainApp.register() } catch { fail("앱을 응용 프로그램 폴더로 옮긴 뒤 다시 시도하거나, 시스템 설정 > 일반 > 로그인 항목에서 직접 추가하세요."); return }
            let status = Self.loginStatus                                                      // success does not mean it is on: ask again
            if LoginItemPolicy.needsApproval(afterRegister: status) { SMAppService.openSystemSettingsLoginItems() }
            else if !LoginItemPolicy.registered(status) { fail("시스템이 로그인 항목을 등록하지 않았습니다.") }
        } else if LoginItemPolicy.shouldUnregister(Self.loginStatus) {
            do { try SMAppService.mainApp.unregister() } catch { fail("시스템 설정 > 일반 > 로그인 항목에서 직접 끄세요.") }
        }
    }

    private static var loginStatus: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .notRegistered
        }
    }
    private static var installScriptAgentExists: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/\(UpdateRules.launchdLabel).plist")
    }

    @objc private func quitTapped() { NSApp.terminate(nil) }

    @objc private func toggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        Settings.setBool(key, sender.state == .on)
    }

    @objc private func stepped(_ sender: NSStepper) {
        guard let key = sender.identifier?.rawValue else { return }
        Settings.setInt(key, sender.integerValue)
        valueLabels[key]?.stringValue = valueText(key, Settings.int(key))
    }

    @objc private func gestureChanged(_ sender: NSPopUpButton) {
        let parts = (sender.identifier?.rawValue ?? "").split(separator: ".").map(String.init)
        guard parts.count == 2, let c = SensorContext(rawValue: parts[0]), let g = SensorGesture(rawValue: parts[1]),
              let raw = sender.selectedItem?.representedObject as? String, let action = SensorAction(rawValue: raw) else { return }
        var map = SensorGestureMap(Settings.sensorGestureMap)
        map.set(action, c, g)
        Settings.sensorGestureMap = map.stored
    }

    @objc private func checkUpdateTapped() { onCheckUpdate() }

    func windowWillClose(_ notification: Notification) { valueLabels = [:]; updateStatusLabel = nil }
}
