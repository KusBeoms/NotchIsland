import Foundation

// Texts / rules of the transfer card, and the monitor against real published NSProgress (in a temporary folder).
@main
struct TransferTests {
    static func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func main() {
        // partial files are named after the file they will become
        assert(TransferRules.displayName("video.mp4.crdownload") == "video.mp4")
        assert(TransferRules.displayName("Archive.zip.download") == "Archive.zip")
        assert(TransferRules.displayName("a.iso.PART") == "a.iso")
        assert(TransferRules.displayName("notes.txt") == "notes.txt")
        assert(TransferRules.displayName(".crdownload") == ".crdownload")          // nothing left of the name: keep it

        assert(TransferRules.operationLabel("NSProgressFileOperationKindDownloading") == "다운로드 중")
        assert(TransferRules.operationLabel("NSProgressFileOperationKindCopying") == "복사 중")
        assert(TransferRules.operationLabel(nil) == "진행 중")
        assert(TransferRules.completionLabel("NSProgressFileOperationKindDownloading") == "다운로드 완료")
        assert(TransferRules.symbol("NSProgressFileOperationKindCopying") == "doc.on.doc.fill")
        assert(TransferRules.symbol(nil) == "arrow.down.circle.fill")

        assert(TransferRules.fraction(completed: 25, total: 100, indeterminate: false) == 0.25)
        assert(TransferRules.fraction(completed: 150, total: 100, indeterminate: false) == 1)      // clamped
        assert(TransferRules.fraction(completed: 5, total: 0, indeterminate: false) == nil)        // total unknown
        assert(TransferRules.fraction(completed: 5, total: 100, indeterminate: true) == nil)
        assert(TransferRules.percentText(0.649) == "64%" && TransferRules.percentText(nil) == "")
        assert(TransferRules.finishedOK(completed: 100, total: 100, cancelled: false))
        assert(!TransferRules.finishedOK(completed: 60, total: 100, cancelled: false))             // stopped half way
        assert(!TransferRules.finishedOK(completed: 100, total: 100, cancelled: true))
        assert(!TransferRules.finishedOK(completed: 0, total: 0, cancelled: false))

        assert(TransferRules.countsBytes(total: 80_000_000) && !TransferRules.countsBytes(total: 10))   // "3 of 10 items" is not bytes
        assert(TransferRules.remainingText(seconds: 0.2) == "1초" && TransferRules.remainingText(seconds: 18) == "18초")
        assert(TransferRules.remainingText(seconds: 60) == "1분" && TransferRules.remainingText(seconds: 200) == "3분 20초")
        assert(TransferRules.remainingText(seconds: 3600) == "1시간" && TransferRules.remainingText(seconds: 3900) == "1시간 5분")
        assert(TransferRules.subtitle(label: "복사 중", bytesPerSecond: nil, remaining: nil) == "복사 중")
        let full = TransferRules.subtitle(label: "다운로드 중", bytesPerSecond: 12_000_000, remaining: 18)
        assert(full.hasPrefix("다운로드 중 · ") && full.contains("/s") && full.hasSuffix(" · 18초 남음"))

        // The monitor against the real thing: publish a download in a folder it watches.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ni-transfer-test-\(getpid())")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let monitor = TransferMonitor()
        var changes = 0
        var finished: [(String, Bool)] = []
        monitor.onChange = { changes += 1 }
        monitor.onFinished = { t, ok in finished.append((t.name, ok)) }
        monitor.start(folders: [folder])
        assert(monitor.transfers.isEmpty)

        func publish(_ name: String, total: Int64, kind: Progress.FileOperationKind) -> Progress {
            let url = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            let p = Progress(totalUnitCount: total)
            p.kind = .file; p.fileOperationKind = kind; p.fileURL = url
            p.publish()
            return p
        }

        let download = publish("clip.mp4.crdownload", total: 100, kind: .downloading)
        spin(0.6)
        assert(monitor.transfers.count == 1 && changes == 1)
        let t = monitor.transfers[0]
        assert(t.name == "clip.mp4" && t.operation == "NSProgressFileOperationKindDownloading" && t.fraction == 0)
        download.completedUnitCount = 40
        spin(0.3)
        assert(t.fraction == 0.4)                                                                  // values are read live

        let copy = publish("big.iso", total: 50, kind: .copying)
        spin(0.6)
        assert(monitor.transfers.count == 2 && monitor.transfers[1].id != t.id)

        download.completedUnitCount = 100
        download.unpublish()
        spin(0.6)
        assert(monitor.transfers.count == 1 && finished.count == 1 && finished[0] == ("clip.mp4", true))

        copy.completedUnitCount = 20                                                               // stopped half way
        copy.unpublish()
        spin(0.6)
        assert(monitor.transfers.isEmpty && finished.count == 2 && finished[1] == ("big.iso", false))

        monitor.stop()
        let late = publish("after-stop.zip", total: 10, kind: .downloading)
        spin(0.5)
        assert(monitor.transfers.isEmpty)                                                          // stopped: nothing is seen
        late.unpublish()
        print("Transfer texts, rules and NSProgress subscription checks passed")
    }
}
