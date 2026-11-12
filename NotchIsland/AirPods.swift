import AppKit
import IOBluetooth
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - AirPods (connected Apple headphones + battery, from the Bluetooth system report)

struct AirPodsInfo {
    var name: String
    var symbol: String
    var level: Int?
    var address: String = ""
    var id: String { address.isEmpty ? name : address.lowercased().replacingOccurrences(of: "-", with: ":") }
}

/// Bluetooth notifications trigger a fresh report; polling remains a fallback for missed events.
final class AirPodsMonitor: NSObject {
    var onChange: (() -> Void)?
    private var connection: IOBluetoothUserNotification?
    private var disconnections: [String: IOBluetoothUserNotification] = [:]
    func start() {
        connection = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(changed(_:device:)))
        observeConnectedDevices()
    }
    func observeConnectedDevices() {
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where device.isConnected() {
            guard let address = device.addressString, disconnections[address] == nil else { continue }
            disconnections[address] = device.register(forDisconnectNotification: self, selector: #selector(changed(_:device:)))
        }
    }
    @objc private func changed(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !device.isConnected(), let address = device.addressString {
                disconnections.removeValue(forKey: address)?.unregister()
            }
            observeConnectedDevices(); onChange?()
        }
    }
    deinit { connection?.unregister(); disconnections.values.forEach { $0.unregister() } }
}

/// A failed report must never be interpreted as a successful empty report.
struct AirPodsConnections {
    private(set) var devices: [String: AirPodsInfo] = [:]
    private var baseline = false
    private var missing = Set<String>()
    mutating func update(_ list: [AirPodsInfo]?) -> [(AirPodsInfo, Bool)] {
        guard let list else { return [] }
        let current = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard baseline else { devices = current; baseline = true; return [] }
        var changes: [(AirPodsInfo, Bool)] = []
        for (id, device) in current where devices[id] == nil { changes.append((device, true)) }
        let absent = Set(devices.keys).subtracting(current.keys)
        for id in absent.intersection(missing) {
            if let device = devices.removeValue(forKey: id) { changes.append((device, false)) }
        }
        missing = absent
        for (id, device) in current { devices[id] = device }
        return changes.sorted { $0.0.id < $1.0.id }
    }
}


func queryAirPods() -> [AirPodsInfo]? {
    let data = runTool("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"], timeout: 10)
    return parseAirPods(data)
}

func parseAirPods(_ data: Data) -> [AirPodsInfo]? {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let first = (j["SPBluetoothDataType"] as? [[String: Any]])?.first else { return nil }
    if let connected = first["device_connected"], !(connected is [[String: Any]]) { return nil }
    let connected = first["device_connected"] as? [[String: Any]] ?? []
    var out: [AirPodsInfo] = []
    for entry in connected {
        for (name, v) in entry {
            guard let info = v as? [String: Any],
                  (info["device_vendorID"] as? String)?.lowercased() == "0x004c",       // Apple
                  (info["device_minorType"] as? String) == "Headphones" else { continue }
            let pid = (info["device_productID"] as? String)?.lowercased() ?? ""
            let levels = ["device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelMain"].compactMap {
                (info[$0] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
            }
            let symbol = pid == "0x200a" ? "airpodsmax"
                : ["0x200e", "0x2014", "0x2024", "0x2027"].contains(pid) ? "airpodspro" : "airpods"
            out.append(AirPodsInfo(name: name, symbol: symbol, level: levels.filter { (0...100).contains($0) }.min(), address: info["device_address"] as? String ?? ""))   // like iPhone: the lower bud
        }
    }
    return out
}

