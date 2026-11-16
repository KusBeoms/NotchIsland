import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - The file pocket: add, remove, drag in and out.

extension App {
    // MARK: files (the pocket)

    func fileAdd(_ urls: [URL]) {
        for u in urls where !files.contains(u) { files.append(u) }
        syncActivities(); fileSave(); refreshUI()
    }
    func fileRemove(_ u: URL) {
        files.removeAll { $0 == u }; slotItems.removeValue(forKey: .file(u))
        syncActivities(); fileSave(); refreshUI()
    }
    @objc func filesClear() {
        clearedFiles = files
        for u in files { slotItems.removeValue(forKey: .file(u)) }
        files.removeAll(); syncActivities(); fileSave(); refreshUI()
    }
    @objc func restoreClearedFiles() {
        fileAdd(clearedFiles); clearedFiles = []
    }
    func fileSave() {
        guard demoShelf == nil else { return }
        UserDefaults.standard.set(files.map { $0.path }, forKey: "pocketFiles")
    }
    func fileLoad() {
        let paths = demoShelf ?? UserDefaults.standard.stringArray(forKey: "pocketFiles") ?? []
        files = paths.map { URL(fileURLWithPath: $0) }
    }
    @objc func revealFileTapped() { if case .file(let u)? = cardKind { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc func removeFileTapped() { if case .file(let u)? = cardKind { fileRemove(u); pinned = false } }

    func fileSubtitle(_ u: URL) -> String {
        guard FileManager.default.fileExists(atPath: u.path) else { return "연결을 확인하세요 · 파일에 접근할 수 없음" }
        if let c = fileInfo[u] { return c }
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let info = [u.deletingLastPathComponent().lastPathComponent, size].compactMap { $0 }.joined(separator: " · ")
        fileInfo[u] = info
        return info
    }

    /// The file a drag starting at the pointer would carry: the open file card's icon / name, or a file icon in the compact island.
    func fileForDrag(_ e: NSEvent) -> URL? {
        if shape == .expanded {
            guard body == .file, case .file(let u)? = cardKind else { return nil }
            return c.fIcon.frame.union(c.fName.frame).contains(c.convert(e.locationInWindow, from: nil)) ? u : nil
        }
        if case .file(let u)? = kindAtMouse() { return u }
        return nil
    }
    func cancelPress() { longPressTimer?.invalidate(); longPressTimer = nil; pressing = false }

    /// Called every frame: is a file drag (from Finder...) in progress, and is it near the notch?
    func trackFileDrag(_ m: NSPoint) {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down && !wasBtn { downChange = NSPasteboard(name: .drag).changeCount; dragActive = false }
        if down, !dragActive {                          // the drag pasteboard is only looked at while the button is held
            let pb = NSPasteboard(name: .drag)
            if pb.changeCount != downChange, pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { dragActive = true }
        }
        if !down { dragActive = false; dragEntered = false }
        wasBtn = down
        let zone = dropping ? frame(for: .expanded).insetBy(dx: -30, dy: -30)
                            : NSRect(x: screen.frame.midX - 110, y: screen.frame.maxY - 70, width: 220, height: 70)
        let near = dragActive && zone.contains(m)
        if near != dragNear { dragNear = near }
    }
}
