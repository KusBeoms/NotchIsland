import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

enum BannerKind {
    case battery(title: String, level: Int, color: NSColor)
    case airpods(symbol: String, level: Int?)
}

// MARK: - Volume / brightness (read, set) and the media keys that drive them

enum SystemLevels {
    static func outputDevice() -> AudioObjectID? {
        var dev = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr, dev != 0 else { return nil }
        return dev
    }
    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static func settable(_ d: AudioObjectID, _ a: inout AudioObjectPropertyAddress) -> Bool {
        var ok: DarwinBoolean = false
        return AudioObjectHasProperty(d, &a) && AudioObjectIsPropertySettable(d, &a, &ok) == noErr && ok.boolValue
    }

    static var volumeControllable: Bool {
        guard let d = outputDevice() else { return false }
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        return settable(d, &a)
    }
    static func volume() -> Float? {
        guard let d = outputDevice() else { return nil }
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(d, &a) else { return nil }
        var v: Float32 = 0; var sz = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr ? v : nil
    }
    @discardableResult static func setVolume(_ v: Float) -> Bool {
        guard let d = outputDevice() else { return false }
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard settable(d, &a) else { return false }
        var x = Float32(min(max(v, 0), 1))
        return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &x) == noErr
    }
    static func muted() -> Bool? {
        guard let d = outputDevice() else { return nil }
        var a = addr(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(d, &a) else { return nil }
        var v: UInt32 = 0; var sz = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr ? v != 0 : nil
    }
    @discardableResult static func setMuted(_ m: Bool) -> Bool {
        guard let d = outputDevice() else { return false }
        var a = addr(kAudioDevicePropertyMute)
        guard settable(d, &a) else { return false }
        var x: UInt32 = m ? 1 : 0
        return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &x) == noErr
    }

    // Brightness goes through the private DisplayServices framework (the same one System Settings uses).
    private static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private typealias GetB = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetB = @convention(c) (UInt32, Float) -> Int32

    static var builtinDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }
    static func brightness() -> Float? {
        guard let h = ds, let sym = dlsym(h, "DisplayServicesGetBrightness"), let id = builtinDisplay else { return nil }
        var b: Float = 0
        return unsafeBitCast(sym, to: GetB.self)(id, &b) == 0 ? b : nil
    }
    static var brightnessControllable: Bool {
        guard let h = ds else { return false }
        return dlsym(h, "DisplayServicesSetBrightness") != nil && brightness() != nil
    }
    @discardableResult static func setBrightness(_ v: Float) -> Bool {
        guard let h = ds, let sym = dlsym(h, "DisplayServicesSetBrightness"), let id = builtinDisplay else { return false }
        return unsafeBitCast(sym, to: SetB.self)(id, min(max(v, 0), 1)) == 0
    }
}

/// Swallows the volume / brightness / mute keys (so the system HUD never fires) and hands them to `onKey`.
/// Needs the Accessibility permission; `install()` simply returns false until it is granted.
final class MediaKeyTap {
    var onKey: ((_ code: Int, _ down: Bool, _ fine: Bool) -> Bool)?   // true = handled (swallow the event)
    private(set) var tap: CFMachPort?
    var isActive: Bool { tap != nil }

    @discardableResult func install() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1) << 14                      // NX_SYSDEFINED: media / function keys
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {     // the system pauses slow taps: turn it back on
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let d1 = ns.data1
        let code = (d1 & 0xFFFF0000) >> 16
        let down = ((d1 & 0x0000FF00) >> 8) == 0xA          // 0xA = key down (also for auto-repeat), 0xB = key up
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)   // Shift+Option = quarter steps
        return (onKey?(code, down, fine) ?? false) ? nil : Unmanaged.passUnretained(event)
    }
}

