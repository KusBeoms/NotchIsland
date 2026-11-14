import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Battery

struct Battery {
    var level: Int
    var plugged: Bool
    var charging: Bool

    var connectionTitle: String {
        if level >= 100 { return "충전됨" }
        return charging ? "충전 중" : "전원 연결됨"
    }
}

/// Battery changes are transient system alerts, never ongoing Live Activities.
struct BatteryNotifications {
    enum Event: Equatable { case connected, lowBattery }

    private var previous: Battery?
    private var warned20 = false
    private var warned10 = false

    mutating func update(_ battery: Battery) -> Event? {
        defer { previous = battery }
        guard let old = previous else {
            // Establish a baseline without announcing a state that predates launch.
            warned20 = !battery.plugged && battery.level <= 20
            warned10 = !battery.plugged && battery.level <= 10
            return nil
        }
        if battery.plugged {
            warned20 = false
            warned10 = false
            // Connection is sufficient: IOKit can report charging=false briefly,
            // and charge limits must not turn a connection into a completion alert.
            return old.plugged ? nil : .connected
        }
        if battery.level <= 10 && !warned10 {
            warned10 = true
            warned20 = true
            return .lowBattery
        }
        if battery.level <= 20 && !warned20 {
            warned20 = true
            return .lowBattery
        }
        return nil
    }
}

func readBattery() -> Battery? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
              (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
              let cur = d[kIOPSCurrentCapacityKey] as? Int,
              let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0 else { continue }
        let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        return Battery(level: cur * 100 / mx, plugged: plugged, charging: charging)
    }
    return nil
}

