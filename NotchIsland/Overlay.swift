import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Staying put while Spaces slide

/// Moves a window into a private top-most "overlay" Space that is shown on top of every desktop. Windows there do not
/// take part in Space transitions (three-finger swipe, Ctrl+arrow), so the island stays at the notch instead of
/// sliding in with the new desktop. Uses private SkyLight calls; if they are missing the window is left as it is.
enum Overlay {
    typealias Conn = @convention(c) () -> Int32
    typealias Create = @convention(c) (Int32, Int32, UnsafeRawPointer?) -> UInt64
    typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    typealias Show = @convention(c) (Int32, CFArray) -> Int32
    typealias Add = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    static var space: UInt64 = 0
    static var ok = false

    static func sym<T>(_ name: String, _ t: T.Type) -> T? {
        guard let h = lib, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: t)
    }

    static func attach(_ w: NSWindow) {
        guard w.windowNumber > 0,
              let conn = sym("SLSMainConnectionID", Conn.self), let create = sym("SLSSpaceCreate", Create.self),
              let level = sym("SLSSpaceSetAbsoluteLevel", SetLevel.self), let show = sym("SLSShowSpaces", Show.self),
              let add = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", Add.self) else { return }
        let cid = conn()
        if space == 0 {
            space = create(cid, 1, nil)
            guard space != 0 else { return }
            _ = level(cid, space, 2_147_483_647)
            _ = show(cid, [NSNumber(value: space)] as CFArray)
            ok = true
        }
        _ = add(cid, space, [NSNumber(value: w.windowNumber)] as CFArray, 7)
    }
}
func makeSticky(_ w: NSWindow) { if ProcessInfo.processInfo.environment["NI_NOOVERLAY"] == nil { Overlay.attach(w) } }   // NI_NOOVERLAY: test hook

func dlog(_ m: String) { if ProcessInfo.processInfo.environment["NI_DEBUG"] != nil { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) } }

// MARK: - Haptics

/// Force Touch trackpad tap. macOS only plays it while a finger is on the trackpad
/// (hovering with the pointer, clicking, touching) — otherwise the call is a silent no-op.
func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
}

