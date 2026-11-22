import Foundation

// MARK: - Shortening long strings for places that cannot wrap (menu items, labels). Pure.

enum TextClip {
    /// `text` cut to at most `limit` characters (whole composed characters), ending in an ellipsis.
    static func tail(_ text: String, limit: Int) -> String {
        guard limit > 1, text.count > limit else { return text }
        var head = String(text.prefix(limit - 1))
        while let last = head.last, last.isWhitespace { head.removeLast() }
        return head + "…"
    }

    /// A file name cut in the middle so that its extension (up to 8 characters) stays visible: "very long na…ame.pdf".
    static func middle(_ name: String, limit: Int) -> String {
        guard limit > 4, name.count > limit else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let keepExt = !ext.isEmpty && ext.count <= 8 && ns.deletingPathExtension.count > 1
        let suffixPart = keepExt ? "." + ext : ""
        let stem = Array(keepExt ? ns.deletingPathExtension : name)
        let room = limit - suffixPart.count - 1                  // one place for the ellipsis
        guard room >= 2 else { return tail(name, limit: limit) }
        let front = (room * 2 + 2) / 3, back = room - front
        return String(stem.prefix(front)) + "…" + String(stem.suffix(back)) + suffixPart
    }
}
