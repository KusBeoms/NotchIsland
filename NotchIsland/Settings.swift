import Foundation

// MARK: - Settings (typed UserDefaults)

/// Every user-facing setting lives here, so the settings window, the menu and the features read one source of truth.
/// Key names of settings that existed before this file (`zeroVolumeOnOutputChange`) are unchanged, so nothing is migrated.
enum Settings {
    /// Tests swap in a throwaway suite so they never touch the real preferences.
    static var store: UserDefaults = .standard
    /// Posted (on the main thread) after any value changes, so running features can react at once.
    static let changed = Notification.Name("NotchIslandSettingsChanged")

    enum Key {
        static let calendar = "calendarEnabled"
        static let privacy = "privacyIndicatorEnabled"
        static let downloads = "downloadsEnabled"
        static let zeroVolume = "zeroVolumeOnOutputChange"
        static let pomodoroWork = "pomodoroWorkMin"
        static let pomodoroBreak = "pomodoroBreakMin"
        static let pomodoroLongBreak = "pomodoroLongBreakMin"
        static let pomodoroLongEvery = "pomodoroLongEvery"
        static let sensorGestures = "sensorGestureMap"
        static let autoUpdate = "autoUpdateEnabled"
    }

    static let boolDefaults: [String: Bool] = [
        Key.calendar: true, Key.privacy: true, Key.downloads: true, Key.zeroVolume: true, Key.autoUpdate: true,
    ]
    /// default, allowed range
    static let intDefaults: [String: (value: Int, range: ClosedRange<Int>)] = [
        Key.pomodoroWork: (25, 1...180), Key.pomodoroBreak: (5, 1...60),
        Key.pomodoroLongBreak: (15, 1...120), Key.pomodoroLongEvery: (4, 2...10),
    ]

    private static func notify() {
        if Thread.isMainThread { NotificationCenter.default.post(name: changed, object: nil) }
        else { DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) } }
    }

    /// `bool(forKey:)` would read an unset key as false; these settings are opt-out, so an unset key means the default.
    static func bool(_ key: String) -> Bool { store.object(forKey: key) as? Bool ?? boolDefaults[key] ?? false }
    static func setBool(_ key: String, _ value: Bool) { store.set(value, forKey: key); notify() }

    static func int(_ key: String) -> Int {
        guard let d = intDefaults[key] else { return 0 }
        let v = store.object(forKey: key) as? Int ?? d.value
        return min(max(v, d.range.lowerBound), d.range.upperBound)
    }
    static func setInt(_ key: String, _ value: Int) {
        guard let d = intDefaults[key] else { return }
        store.set(min(max(value, d.range.lowerBound), d.range.upperBound), forKey: key); notify()
    }

    static var calendarEnabled: Bool { bool(Key.calendar) }
    static var privacyEnabled: Bool { bool(Key.privacy) }
    static var downloadsEnabled: Bool { bool(Key.downloads) }
    static var zeroVolumeOnOutputChange: Bool { bool(Key.zeroVolume) }
    static var autoUpdateEnabled: Bool { bool(Key.autoUpdate) }

    static var pomodoro: PomodoroConfig {
        PomodoroConfig(work: int(Key.pomodoroWork), rest: int(Key.pomodoroBreak),
                       longRest: int(Key.pomodoroLongBreak), longEvery: int(Key.pomodoroLongEvery))
    }

    /// "context.gesture" -> action raw value. Missing entries fall back to the built-in defaults (SensorGesture.swift).
    static var sensorGestureMap: [String: String] {
        get { store.dictionary(forKey: Key.sensorGestures) as? [String: String] ?? [:] }
        set { store.set(newValue, forKey: Key.sensorGestures); notify() }
    }
}
