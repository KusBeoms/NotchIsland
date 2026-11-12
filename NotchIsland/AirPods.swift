import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - AirPods (connected Apple headphones + battery, from the Bluetooth system report)

struct AirPodsInfo { var name: String; var symbol: String; var level: Int? }

func queryAirPods() -> [AirPodsInfo] {
    let data = runTool("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"], timeout: 10)
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let first = (j["SPBluetoothDataType"] as? [[String: Any]])?.first,
          let connected = first["device_connected"] as? [[String: Any]] else { return [] }
    var out: [AirPodsInfo] = []
    for entry in connected {
        for (name, v) in entry {
            guard let info = v as? [String: Any],
                  (info["device_vendorID"] as? String)?.lowercased() == "0x004c",       // Apple
                  (info["device_minorType"] as? String) == "Headphones" else { continue }
            let pid = (info["device_productID"] as? String)?.lowercased() ?? ""
            let levels = ["device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelMain"].compactMap {
                (info[$0] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
            }
            let symbol = pid == "0x200a" ? "airpodsmax"
                : ["0x200e", "0x2014", "0x2024", "0x2027"].contains(pid) ? "airpodspro" : "airpods"
            out.append(AirPodsInfo(name: name, symbol: symbol, level: levels.min()))   // like iPhone: the lower bud
        }
    }
    return out
}

