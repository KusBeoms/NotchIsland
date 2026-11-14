import Foundation

// No battery hardware is required: exercise the same transitions used by App.
@main
struct BatteryTests {
    static func main() {
        func battery(_ level: Int, plugged: Bool = false, charging: Bool = false) -> Battery {
            Battery(level: level, plugged: plugged, charging: charging)
        }

        var state = BatteryNotifications()
        assert(state.update(battery(60)) == nil)
        // Delayed charging status must not swallow the connection notification.
        assert(state.update(battery(60, plugged: true)) == .connected)
        assert(state.update(battery(60, plugged: true, charging: true)) == nil)
        assert(state.update(battery(80, plugged: true)) == nil) // Charge limit, not completion.
        assert(state.update(battery(100, plugged: true)) == nil)
        assert(state.update(battery(100)) == nil) // Disconnect silently.
        assert(state.update(battery(100, plugged: true)) == .connected)
        assert(state.update(battery(100, plugged: true)) == nil)

        assert(state.update(battery(21)) == nil)
        assert(state.update(battery(20)) == .lowBattery)
        assert(state.update(battery(20)) == nil)
        assert(state.update(battery(11)) == nil)
        assert(state.update(battery(10)) == .lowBattery)
        assert(state.update(battery(9)) == nil)
        assert(state.update(battery(11)) == nil)
        assert(state.update(battery(10)) == nil) // No repeated warnings from level jitter.
        assert(state.update(battery(9, plugged: true)) == .connected)
        assert(state.update(battery(9, plugged: true, charging: true)) == nil)
        assert(state.update(battery(9)) == .lowBattery) // New discharge session.
        assert(state.update(battery(9)) == nil)

        var lowAtLaunch = BatteryNotifications()
        assert(lowAtLaunch.update(battery(15)) == nil)
        assert(lowAtLaunch.update(battery(14)) == nil)
        assert(lowAtLaunch.update(battery(8)) == .lowBattery)
        assert(lowAtLaunch.update(battery(8)) == nil)
        var criticalAtLaunch = BatteryNotifications()
        assert(criticalAtLaunch.update(battery(5)) == nil)
        assert(criticalAtLaunch.update(battery(4)) == nil)
        var pluggedAtLaunch = BatteryNotifications()
        assert(pluggedAtLaunch.update(battery(80, plugged: true)) == nil)
        assert(pluggedAtLaunch.update(battery(100, plugged: true)) == nil)
        var skippedThreshold = BatteryNotifications()
        assert(skippedThreshold.update(battery(30)) == nil)
        assert(skippedThreshold.update(battery(8)) == .lowBattery)
        assert(skippedThreshold.update(battery(8)) == nil)
        print("Battery notification transition checks passed")
    }
}
