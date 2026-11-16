import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Keyboard focus inside the open island.

extension App {
    var keyboardControls: [NSView] {
        let controls: [NSView]
        switch body {
        case .media: controls = [c.prevB, c.playB, c.nextB, c.lyricsB, c.progress]
        case .timer: controls = [c.pauseB, c.cancelB]
        case .file: controls = [c.fRevealB, c.fRemoveB]
        case .hud: controls = [c.hBar]
        default: controls = []
        }
        return controls.filter { !$0.isHidden && (($0 as? NSControl)?.isEnabled ?? true) }
    }
    func releaseKeyboardFocus() {
        KeyboardFocus.visible = false
        panel.resignKey()
        let previous = keyboardReturnApp
        keyboardReturnApp = nil
        if let previous, !previous.isTerminated { previous.activate(options: []) }
    }
    func focusIsland() {
        KeyboardFocus.visible = false
        if let previous = NSWorkspace.shared.frontmostApplication, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            keyboardReturnApp = previous
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        let controls = keyboardControls
        for (index, control) in controls.enumerated() { control.nextKeyView = controls[(index + 1) % controls.count] }
        panel.makeFirstResponder(controls.first ?? view)
    }
    func advanceKeyboardSelection(backwards: Bool) {
        let controls = keyboardControls
        guard !controls.isEmpty else { return }
        let current = controls.firstIndex { $0 === panel.firstResponder }
        let index = current.map { ($0 + (backwards ? -1 : 1) + controls.count) % controls.count } ?? (backwards ? controls.count - 1 : 0)
        let previous = panel.firstResponder as? NSView
        panel.makeFirstResponder(controls[index])
        previous?.needsDisplay = true; controls[index].needsDisplay = true
    }
}
