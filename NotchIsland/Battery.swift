import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Battery

struct Battery { var level: Int; var plugged: Bool; var charging: Bool }

/// Full = plugged in and no longer charging near the top. Also covers macOS charge limits (80–95%).
func isFull(_ b: Battery) -> Bool { b.plugged && ((b.level >= 100) || (!b.charging && b.level >= 80)) }

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

