import Foundation

// MARK: - File transfers (downloads, copies): the texts and rules, without any system access

enum TransferRules {
    /// Browsers write to a partial file and rename it when done: "video.mp4.crdownload" is "video.mp4" to the user.
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "opdownload", "partial"]

    static func displayName(_ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard partialExtensions.contains(ext) else { return fileName }
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? fileName : base
    }

    /// `NSProgressFileOperationKind...` raw value -> what is going on.
    static func operationLabel(_ rawKind: String?) -> String {
        switch rawKind {
        case "NSProgressFileOperationKindDownloading": return "다운로드 중"
        case "NSProgressFileOperationKindCopying": return "복사 중"
        case "NSProgressFileOperationKindReceiving": return "받는 중"
        case "NSProgressFileOperationKindDecompressingAfterDownloading": return "압축 해제 중"
        case "NSProgressFileOperationKindUploading": return "업로드 중"
        case "NSProgressFileOperationKindDuplicating": return "복제 중"
        default: return "진행 중"
        }
    }
    static func completionLabel(_ rawKind: String?) -> String {
        switch rawKind {
        case "NSProgressFileOperationKindDownloading": return "다운로드 완료"
        case "NSProgressFileOperationKindCopying": return "복사 완료"
        case "NSProgressFileOperationKindReceiving": return "받기 완료"
        case "NSProgressFileOperationKindUploading": return "업로드 완료"
        default: return "완료"
        }
    }
    static func symbol(_ rawKind: String?) -> String {
        switch rawKind {
        case "NSProgressFileOperationKindCopying", "NSProgressFileOperationKindDuplicating": return "doc.on.doc.fill"
        case "NSProgressFileOperationKindUploading": return "arrow.up.circle.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    /// 0...1, or nil when the total is not known (then there is no percentage to show).
    static func fraction(completed: Int64, total: Int64, indeterminate: Bool) -> Double? {
        guard !indeterminate, total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    /// Unpublished at 100% = done; unpublished earlier (or cancelled) = it was stopped.
    static func finishedOK(completed: Int64, total: Int64, cancelled: Bool) -> Bool {
        !cancelled && total > 0 && completed >= total
    }

    /// Byte counts only look like bytes for real files: a progress counting 3 of 10 items must not be shown as "3 B/s".
    static func countsBytes(total: Int64) -> Bool { total >= 1_000_000 }

    static func speedText(bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(bytesPerSecond, 0)), countStyle: .file) + "/s"
    }
    static func remainingText(seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return "\(max(s, 1))초" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)분" : "\(s / 60)분 \(s % 60)초" }
        return (s % 3600) / 60 == 0 ? "\(s / 3600)시간" : "\(s / 3600)시간 \((s % 3600) / 60)분"
    }

    /// The second line of the card: "다운로드 중 · 12 MB/s · 18초 남음" (the parts that are known).
    static func subtitle(label: String, bytesPerSecond: Double?, remaining: TimeInterval?) -> String {
        var parts = [label]
        if let v = bytesPerSecond, v > 0 { parts.append(speedText(bytesPerSecond: v)) }
        if let r = remaining, r.isFinite, r >= 0 { parts.append("\(remainingText(seconds: r)) 남음") }
        return parts.joined(separator: " · ")
    }
    static func percentText(_ fraction: Double?) -> String {
        fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? ""
    }
}
