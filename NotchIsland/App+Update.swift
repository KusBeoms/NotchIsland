import AppKit

// MARK: - Auto update (the engine is Updater.swift): wiring, menu item and feedback in the island.

extension App {
    func setupUpdater() {
        updater.isIdle = { [weak self] in !(self?.timer.started ?? false) }       // a running / paused timer would be lost
        updater.onWillRelaunch = { [weak self] in self?.releaseAutoBrightness() }
        updater.onRelaunch = { NSApp.terminate(nil) }
        updater.onChange = { [weak self] in self?.settingsWindow.refreshUpdateStatus() }
        updater.onManualResult = { [weak self] state in self?.announceCheckResult(state) }
        settingsWindow.updateStatus = { [weak self] in self?.updater.statusText ?? "" }
        settingsWindow.onCheckUpdate = { [weak self] in self?.menuCheckUpdate() }        // same guard as the menu item
        updater.cleanupStaging()
        applyUpdateSetting()
        announceUpdateIfNew()
    }

    /// Only a plain launch updates by itself: demo / test runs (any argument, or NI_NOUPDATE) never touch the installed app.
    var updatesAllowed: Bool {
        CommandLine.arguments.count == 1 && ProcessInfo.processInfo.environment["NI_NOUPDATE"] == nil
    }

    /// Called at launch and after every change in the settings window.
    func applyUpdateSetting() {
        guard updatesAllowed else { updater.stopAutomaticChecks(); updater.autoApply = false; return }
        updater.autoApply = Settings.autoUpdateEnabled
        if Settings.autoUpdateEnabled { updater.startAutomaticChecks(); updater.considerApplying() }
        else { updater.stopAutomaticChecks() }
    }

    func updateMenuItem() -> NSMenuItem {
        func item(_ title: String, _ action: Selector?) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.isEnabled = action != nil
            return i
        }
        switch updater.state {
        case .ready(let v): return item("v\(v)로 업데이트하고 다시 시작", #selector(menuInstallUpdate))
        case .available(let v): return item("새 버전 v\(v) 받으러 가기…", #selector(menuOpenReleases))
        case .checking: return item("업데이트 확인 중…", nil)
        case .downloading(let v): return item("v\(v) 내려받는 중…", nil)
        case .idle, .upToDate, .failed: return item("업데이트 확인…", #selector(menuCheckUpdate))
        }
    }

    @objc func menuCheckUpdate() {
        guard updatesAllowed else { showAlert("이 실행에서는 업데이트를 확인하지 않습니다", seconds: 3); return }
        updater.check(manual: true)
    }

    @objc func menuOpenReleases() { NSWorkspace.shared.open(UpdateRules.releasesPageURL) }

    @objc func menuInstallUpdate() {
        if timer.started {
            let alert = NSAlert()
            alert.messageText = "지금 다시 시작할까요?"
            alert.informativeText = "실행 중인 타이머가 초기화됩니다."
            alert.addButton(withTitle: "다시 시작"); alert.addButton(withTitle: "취소")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        updater.applyAndRelaunch()
    }

    func announceCheckResult(_ state: Updater.State) {
        switch state {
        case .upToDate: showAlert("최신 버전입니다 (v\(updater.currentVersion))", seconds: 3)
        case .ready(let v):
            showAlert(updater.autoApply ? "v\(v) 준비됨 · 앱이 쉴 때 자동으로 다시 시작합니다" : "v\(v) 준비됨 · 메뉴에서 다시 시작하세요", seconds: 4)
        case .available(let v): showAlert("새 버전 v\(v)이 있습니다 · 메뉴에서 받을 수 있습니다", seconds: 4)
        case .failed(let message): showAlert("업데이트 확인 실패 · \(message)", seconds: 4)
        case .idle, .checking, .downloading: break
        }
    }

    /// After a silent update the app comes back by itself: say which version it is now.
    func announceUpdateIfNew() {
        let key = "lastLaunchedVersion"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(updater.currentVersion, forKey: key)
        guard updatesAllowed, let previous, UpdateRules.isNewer(updater.currentVersion, than: previous) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.showAlert("NotchIsland v\(self.updater.currentVersion)로 업데이트되었습니다", seconds: 4)
        }
    }
}
