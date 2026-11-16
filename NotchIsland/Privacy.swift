import AppKit
import CoreAudio
import CoreMediaIO

// MARK: - Microphone / camera in use

/// What is capturing right now.
struct PrivacyState: Equatable {
    var mic = false
    var camera = false
    var micApps: [String] = []           // names of the apps that are recording, sorted

    var isActive: Bool { mic || camera }
    var title: String { mic && camera ? "카메라·마이크 사용 중" : (camera ? "카메라 사용 중" : "마이크 사용 중") }
    /// Who is recording. The camera's owner cannot be known through public API, so a camera-only state has none.
    var subtitle: String {
        guard !micApps.isEmpty else { return "" }
        let shown = micApps.prefix(2).joined(separator: ", ")
        return micApps.count > 2 ? "\(shown) 외 \(micApps.count - 2)" : shown
    }
}

enum PrivacyRules {
    /// Daemons that keep the microphone open all the time without the user recording anything (Hey Siri listening).
    /// macOS's own orange dot ignores them as well.
    static let alwaysListening: Set<String> = ["com.apple.CoreSpeech"]

    static func ignored(bundleID: String) -> Bool { alwaysListening.contains(bundleID) }

    /// Audio is often captured by a helper process ("company.browser.helper"): name the app that owns it instead, i.e.
    /// the longest running bundle ID that is the helper's ID or a dotted prefix of it.
    static func owner(of bundleID: String, among running: [String]) -> String? {
        running.filter { bundleID == $0 || bundleID.hasPrefix($0 + ".") }.max { $0.count < $1.count }
    }
}

/// Watches the microphone (per process) and the cameras (per device) and reports changes, debounced.
/// Only asks "is it running?": no capture, so no microphone / camera permission is involved.
///
/// The microphone is read per process (macOS 14.2+) rather than per device: a headset is one device for both directions, and
/// "device is running" would be true while you merely listen to music through it.
final class PrivacyMonitor {
    var onChange: ((PrivacyState) -> Void)?
    private(set) var state = PrivacyState()
    private var started = false
    private var settleItem: DispatchWorkItem?
    private let settleDelay: TimeInterval = 0.4        // brief flickers (an app probing the mic) never reach the island

    private var systemAudioBlock: AudioObjectPropertyListenerBlock?
    private var processBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var systemCameraBlock: CMIOObjectPropertyListenerBlock?
    private var cameraBlocks: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]

    func start() {
        guard !started else { return }
        started = true
        let schedule: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleSettle() }
        systemAudioBlock = schedule
        var processList = Self.audioAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processList, .main, schedule)
        let cameraSchedule: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleSettle() }
        systemCameraBlock = cameraSchedule
        var deviceList = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &deviceList, .main, cameraSchedule)
        settle()                                         // the state right now, without waiting
    }

    func stop() {
        guard started else { return }
        started = false
        settleItem?.cancel(); settleItem = nil
        if let block = systemAudioBlock {
            var processList = Self.audioAddress(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processList, .main, block)
        }
        if let block = systemCameraBlock {
            var deviceList = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &deviceList, .main, block)
        }
        systemAudioBlock = nil; systemCameraBlock = nil
        for (id, block) in processBlocks {
            var a = Self.audioAddress(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
        for (id, block) in cameraBlocks {
            var a = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            CMIOObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
        processBlocks = [:]; cameraBlocks = [:]
        state = PrivacyState()
    }

    private func scheduleSettle() {
        settleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.settle() }
        settleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: item)
    }

    /// Re-reads everything (the sets of processes and cameras change as apps come and go), and reports a change.
    private func settle() {
        guard started else { return }
        let fresh = readState()
        if fresh != state { state = fresh; onChange?(fresh) }
    }

    // MARK: reading

    private func readState() -> PrivacyState {
        var s = PrivacyState()
        let me = ProcessInfo.processInfo.processIdentifier
        let system = AudioObjectID(kAudioObjectSystemObject)
        let processes = Self.audioIDs(system, kAudioHardwarePropertyProcessObjectList)

        // listen to every process' input flag; forget the processes that are gone
        let schedule: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleSettle() }
        for id in processes where processBlocks[id] == nil {
            var a = Self.audioAddress(kAudioProcessPropertyIsRunningInput)
            if AudioObjectAddPropertyListenerBlock(id, &a, .main, schedule) == noErr { processBlocks[id] = schedule }
        }
        for id in processBlocks.keys where !processes.contains(id) { processBlocks[id] = nil }       // gone with the process

        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        var names = Set<String>()
        for id in processes where Self.audioUInt32(id, kAudioProcessPropertyIsRunningInput) == 1 {
            let pid = pid_t(Self.audioUInt32(id, kAudioProcessPropertyPID) ?? 0)
            guard pid != me else { continue }            // our own audio tap shows up as "recording"
            let bundle = Self.audioString(id, kAudioProcessPropertyBundleID) ?? ""
            guard !PrivacyRules.ignored(bundleID: bundle) else { continue }
            s.mic = true
            names.insert(Self.name(pid: pid, bundleID: bundle, running: running))
        }
        s.micApps = names.sorted()

        // cameras
        let devices = Self.cameraIDs()
        let cameraSchedule: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleSettle() }
        for id in devices where cameraBlocks[id] == nil {
            var a = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            if CMIOObjectAddPropertyListenerBlock(id, &a, .main, cameraSchedule) == noErr { cameraBlocks[id] = cameraSchedule }
        }
        for id in cameraBlocks.keys where !devices.contains(id) { cameraBlocks[id] = nil }
        s.camera = devices.contains { Self.cameraRunning($0) }
        return s
    }

    private static func name(pid: pid_t, bundleID: String, running: [String]) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
        if let owner = PrivacyRules.owner(of: bundleID, among: running),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: owner).first, let n = app.localizedName { return n }
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
        return bundleID.split(separator: ".").last.map(String.init) ?? "알 수 없는 앱"
    }

    // MARK: CoreAudio / CoreMediaIO plumbing

    private static func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func audioIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = audioAddress(selector), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
    private static func audioUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = audioAddress(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value : nil
    }
    private static func audioString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = audioAddress(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func cameraAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
    private static func cameraIDs() -> [CMIOObjectID] {
        var a = cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)), size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &a, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }
    private static func cameraRunning(_ id: CMIOObjectID) -> Bool {
        var a = cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var value: UInt32 = 0, used: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr && value != 0
    }
}
