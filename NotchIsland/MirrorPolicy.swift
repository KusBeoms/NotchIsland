import CoreGraphics

// MARK: - Display mirroring: the island is a notch-shaped UI, so it only makes sense on the notch screen itself.
//
// Investigation (code and documentation, nothing could be run here):
//  - With display mirroring the window server presents ONE desktop (the master's); mirrored slaves leave `NSScreen.screens` and the
//    active display list, but stay in the online list (`CGGetOnlineDisplayList`) and report `CGDisplayIsInMirrorSet`.
//  - When the built-in display is the master, our window still lives on it at the notch position, but the picture sent to the
//    TV / external display is that desktop scaled to another aspect ratio (and the notch cut-out is not part of it): the island
//    would be drawn off-centre and squashed there, and a notch-shaped silhouette means nothing without the notch.
//  - When the built-in display is the slave, `NSScreen` no longer has a notch screen at all (`pickScreen` falls back to another one).
// So there is no case where drawing the island is both safe and correctly proportioned: while the built-in display is in a mirror
// set the island is hidden (its state keeps running), and it comes back when mirroring ends.

/// What the window server says about one display. Plain values, so the rule is tested without any display.
struct DisplayMirrorInfo: Equatable {
    var id: UInt32
    var isBuiltin: Bool
    var inMirrorSet: Bool          // master or slave of a mirror set
    var mirrorsDisplay: UInt32     // the master's id when this display is a slave, else 0
}

enum MirrorPolicy {
    /// The built-in (notch) display takes part in mirroring, as master or as slave.
    static func builtinMirrored(_ displays: [DisplayMirrorInfo]) -> Bool {
        displays.contains { $0.isBuiltin && ($0.inMirrorSet || $0.mirrorsDisplay != 0) }
    }

    /// Hide the island: only when the user wants that (the setting) and the built-in display is mirrored. An external display
    /// that mirrors another external one, or no built-in display at all (lid closed), does not count.
    static func shouldHide(_ displays: [DisplayMirrorInfo], enabled: Bool) -> Bool {
        enabled && builtinMirrored(displays)
    }

    /// The new "hidden" state. A list that could not be read (nil) or is empty says nothing, so the previous state stays: a failed
    /// query must neither flash the island on nor hide it.
    static func nextHidden(previous: Bool, displays: [DisplayMirrorInfo]?, enabled: Bool) -> Bool {
        guard let displays, !displays.isEmpty else { return previous }
        return shouldHide(displays, enabled: enabled)
    }

    /// The live state, from every online display (a mirrored slave is online but not active); nil when it cannot be read.
    static func current() -> [DisplayMirrorInfo]? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 else { return nil }
        return ids.prefix(Int(count)).map {
            DisplayMirrorInfo(id: $0, isBuiltin: CGDisplayIsBuiltin($0) != 0, inMirrorSet: CGDisplayIsInMirrorSet($0) != 0,
                              mirrorsDisplay: CGDisplayMirrorsDisplay($0))
        }
    }
}
