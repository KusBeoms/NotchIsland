import AppKit
import QuickLookThumbnailing

/// Shares Quick Look results between the compact slots, open card and drag image.
/// The key includes file metadata so edits and reconnected volumes invalidate old results.
final class FilePreviews {
    static let shared = FilePreviews()
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    private var retryAfter: [String: Date] = [:]

    init() { cache.countLimit = 80 }

    func key(for url: URL) -> String {
        // URL resource values can be cached on the URL instance after a file is edited.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(url.path)|\(modified)|\(size)"
    }

    func cached(for url: URL) -> NSImage? { cache.object(forKey: key(for: url) as NSString) }

    func load(_ url: URL, key: String, completion: @escaping (NSImage?) -> Void) {
        if let image = cache.object(forKey: key as NSString) { completion(image); return }
        if let retry = retryAfter[key], retry > Date() { completion(nil); return }
        if pending[key] != nil { pending[key]?.append(completion); return }
        pending[key] = [completion]
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128),
                                                   scale: 2, representationTypes: .thumbnail)
        request.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let image = thumbnail?.nsImage
                if let image { self.cache.setObject(image, forKey: key as NSString) }
                else {
                    if self.retryAfter.count > 80 { self.retryAfter.removeAll() }
                    self.retryAfter[key] = Date().addingTimeInterval(30)
                }
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(image) }
            }
        }
    }
}

/// Shows an immediate fallback, then fades to the real file thumbnail without blocking the UI.
final class FilePreviewView: NSImageView {
    private var representedKey: String?
    private var representedURL: URL?
    private var checkedAt = Date.distantPast
    private var loaded = false

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setFile(_ url: URL) {
        guard representedURL != url || Date().timeIntervalSince(checkedAt) >= 3 else { return }
        checkedAt = Date()
        let key = FilePreviews.shared.key(for: url)
        if representedKey == key && loaded { return }
        if representedKey != key {
            representedKey = key; representedURL = url; loaded = false
            image = NSWorkspace.shared.icon(forFile: url.path)
            toolTip = url.lastPathComponent
            setAccessibilityLabel(url.lastPathComponent + " 미리보기")
        }
        FilePreviews.shared.load(url, key: key) { [weak self] image in
            guard let self, self.representedKey == key, let image else { return }
            self.loaded = true
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CATransition(); fade.type = .fade; fade.duration = 0.2
                self.layer?.add(fade, forKey: "filePreview")
            }
            self.image = image
        }
    }
}
