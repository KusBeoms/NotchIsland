import Foundation

// MARK: - Start at login: what the settings checkbox shows and does (pure; the system calls live in SettingsWindow)

/// `SMAppService.Status`, copied so the rules can be tested without the framework.
enum LoginItemStatus: Equatable { case notRegistered, enabled, requiresApproval, notFound }

enum LoginItemPolicy {
    /// What the checkbox looks like. `install.sh` starts the app through its own launchd agent: while that exists the checkbox
    /// is off limits (two mechanisms would fight over the same job) and says so.
    static func checkbox(status: LoginItemStatus, agentPlistExists: Bool) -> (on: Bool, enabled: Bool, note: String?) {
        if agentPlistExists { return (true, false, "install.sh 로그인 항목을 사용 중입니다") }
        switch status {
        case .enabled: return (true, true, nil)
        case .requiresApproval: return (true, true, "시스템 설정 > 일반 > 로그인 항목에서 허용해야 합니다")
        case .notRegistered, .notFound: return (false, true, nil)
        }
    }

    /// Only a registered (or waiting for approval) item has anything to remove.
    static func shouldUnregister(_ status: LoginItemStatus) -> Bool { status == .enabled || status == .requiresApproval }

    /// After `register()` returned: the user still has to approve it in System Settings.
    static func needsApproval(afterRegister status: LoginItemStatus) -> Bool { status == .requiresApproval }

    /// Registered at all? (a success that left the status at "not registered" is a failure)
    static func registered(_ status: LoginItemStatus) -> Bool { status == .enabled || status == .requiresApproval }
}
