import Foundation

// MARK: - Transfers published by other apps (NSProgress file progress)

/// Browsers and Finder publish file progress (`Progress.publish()`); this subscribes to it for a few folders. Nothing is read from
/// disk and no file is touched, so it needs no file permission. The system only delivers progress of files directly inside a
/// subscribed folder, not of anything deeper, so a copy to some arbitrary folder cannot be seen.
/// Not really Sendable: every access to its state happens on the main queue (the subscription callbacks hop there first).
final class TransferMonitor: @unchecked Sendable {
    final class Transfer {
        let id: Int
        let progress: Progress
        let startedAt = Date()
        let startCompleted: Int64
        init(id: Int, progress: Progress) { self.id = id; self.progress = progress; startCompleted = progress.completedUnitCount }

        var url: URL? { progress.fileURL ?? progress.userInfo[.fileURLKey] as? URL }
        var operation: String? { progress.fileOperationKind?.rawValue ?? progress.userInfo[.fileOperationKindKey] as? String }
        var name: String { url.map { TransferRules.displayName($0.lastPathComponent) } ?? "파일" }
        var fraction: Double? {
            TransferRules.fraction(completed: progress.completedUnitCount, total: progress.totalUnitCount, indeterminate: progress.isIndeterminate)
        }
        /// Average since this app first saw it (the publisher's own estimate is rarely set).
        var bytesPerSecond: Double? {
            guard TransferRules.countsBytes(total: progress.totalUnitCount) else { return nil }
            let elapsed = Date().timeIntervalSince(startedAt)
            guard elapsed >= 1.5 else { return nil }
            let rate = Double(progress.completedUnitCount - startCompleted) / elapsed
            return rate > 0 ? rate : nil
        }
        var remaining: TimeInterval? {
            guard let rate = bytesPerSecond, progress.totalUnitCount > 0 else { return nil }
            return Double(progress.totalUnitCount - progress.completedUnitCount) / rate
        }
    }

    private(set) var transfers: [Transfer] = []          // main thread only
    /// A transfer appeared or disappeared (progress values are read live and need no notification).
    var onChange: (() -> Void)?
    /// A transfer ended: `ok` when it reached 100%, false when it was stopped half way.
    var onFinished: ((Transfer, Bool) -> Void)?

    private var tokens: [Any] = []
    private var nextID = 1
    private var started = false

    static var defaultFolders: [URL] {
        let fm = FileManager.default
        return [.downloadsDirectory, .desktopDirectory, .documentDirectory].compactMap { fm.urls(for: $0, in: .userDomainMask).first }
    }

    func start(folders: [URL] = TransferMonitor.defaultFolders) {
        guard !started else { return }
        started = true
        for folder in folders {
            let token = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
                // delivered on an arbitrary thread
                DispatchQueue.main.async { self?.add(progress) }
                return { DispatchQueue.main.async { self?.finish(progress) } }
            }
            tokens.append(token)
        }
    }

    func stop() {
        guard started else { return }
        started = false
        for token in tokens { Progress.removeSubscriber(token) }
        tokens = []
        if !transfers.isEmpty { transfers = []; onChange?() }
    }

    private func add(_ progress: Progress) {
        guard started, !transfers.contains(where: { $0.progress === progress }) else { return }
        transfers.append(Transfer(id: nextID, progress: progress)); nextID += 1
        onChange?()
    }

    private func finish(_ progress: Progress) {
        guard let i = transfers.firstIndex(where: { $0.progress === progress }) else { return }
        let t = transfers.remove(at: i)
        let ok = TransferRules.finishedOK(completed: progress.completedUnitCount, total: progress.totalUnitCount, cancelled: progress.isCancelled)
        onFinished?(t, ok)
        onChange?()
    }

    // MARK: demo

    private var demoTimer: Timer?
    /// `--demo-transfer`: a fake 80 MB download that advances by itself, then completes.
    func startDemo() {
        let progress = Progress(totalUnitCount: 80_000_000)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/디자인-시안.zip.crdownload")
        started = true
        add(progress)
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            progress.completedUnitCount += 2_400_000
            if progress.completedUnitCount >= progress.totalUnitCount { t.invalidate(); self?.finish(progress) }
        }
    }
}
