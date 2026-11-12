import Foundation

// This test exercises report parsing and state transitions without querying Bluetooth hardware.
func runTool(_ path: String, _ args: [String], timeout: TimeInterval) -> Data { Data() }

@main
struct AirPodsTests {
    static func main() {
        let pod = AirPodsInfo(name: "AirPods Pro", symbol: "airpodspro", level: 70, address: "AA-BB-CC")
        var state = AirPodsConnections()
        assert(state.update([]).isEmpty)
        let connected = state.update([pod])
        assert(connected.count == 1 && connected[0].1)
        assert(state.update([pod]).isEmpty) // Repeated polls never repeat the banner.
        var renamed = pod
        renamed.name = "새 이름"; renamed.address = "aa:bb:cc"
        assert(state.update([renamed]).isEmpty) // Identity survives a device rename.
        assert(state.update(nil).isEmpty && state.devices.count == 1)
        assert(state.update([]).isEmpty && state.devices.count == 1)
        assert(state.update([pod]).isEmpty) // A transient disappearance is not a disconnect.
        assert(state.update([]).isEmpty)
        let disconnected = state.update([])
        assert(disconnected.count == 1 && !disconnected[0].1 && state.devices.isEmpty)
        assert(state.update([]).isEmpty)
        assert(state.update([pod]).count == 1) // Reconnection is a new event.
        var initial = AirPodsConnections()
        assert(initial.update([pod]).isEmpty) // Already-connected devices stay quiet at launch.

        let report: [String: Any] = ["SPBluetoothDataType": [["device_connected": [
            ["AirPods": ["device_vendorID": "0x004c", "device_minorType": "Headphones",
                         "device_productID": "0x200e", "device_address": "AA-BB-CC",
                         "device_batteryLevelLeft": " 80%", "device_batteryLevelRight": "65%"]]
        ]]]]
        let result = parseAirPods(try! JSONSerialization.data(withJSONObject: report))!
        assert(result.count == 1 && result[0].level == 65 && result[0].id == "aa:bb:cc")
        assert(parseAirPods(Data("invalid".utf8)) == nil)
        assert(parseAirPods(Data("{}".utf8)) == nil)
        assert(parseAirPods(Data(#"{"SPBluetoothDataType":[{}]}"#.utf8))?.isEmpty == true)
        print("AirPods parser and connection transition checks passed")
    }
}
