import Foundation
import SQLite3

/// A short monotonic reveal, independent of the island's spring animation.
struct LyricsWidthTransition {
    var from: Double
    var to: Double
    var start: TimeInterval
    let duration: TimeInterval = 0.18
    func value(at time: TimeInterval) -> Double {
        let t = min(1, max(0, (time - start) / duration))
        return from + (to - from) * t * t * (3 - 2 * t)
    }
    func finished(at time: TimeInterval) -> Bool { time >= start + duration }
}

/// A capped follower keeps ordinary line changes animated even when no instrumental gap exists.
struct LyricsScrollFollower {
    private(set) var position: Double = 0
    let maximumSpeed: Double = 3 // rows per second (120pt/s at the normal 40pt row pitch)
    mutating func reset(to value: Double) { position = value }
    mutating func advance(toward target: Double, deltaTime: Double) {
        let dt = min(1.0 / 15, max(0, deltaTime))
        guard dt > 0 else { return }
        let distance = target - position
        let eased = distance * (1 - exp(-12 * dt))
        let limit = maximumSpeed * dt
        position += min(limit, max(-limit, eased))
    }
}

struct LyricsTrack: Hashable {
    var title: String
    var artist: String
    var album: String
    var duration: Int
    var catalogID: String
}

struct LyricsWord: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var range: NSRange
    func progress(at time: TimeInterval) -> Double {
        min(1, max(0, (time - start) / max(0.01, end - start)))
    }
    /// Sung text rises gently and stays raised while its sentence is in focus; font metrics never change.
    func lift(at time: TimeInterval, emphasis: Double, reduceMotion: Bool, minimumRiseDuration: Double = 0) -> Double {
        guard !reduceMotion, time > start else { return 0 }
        let duration = max(0.01, end - start)
        let riseDuration = max(minimumRiseDuration, min(0.2, duration * 0.6))
        let t = min(1, max(0, (time - start) / riseDuration))
        // Seventh-order smoothstep: velocity, acceleration and jerk vanish at both ends.
        let eased = t * t * t * t * (35 + t * (-84 + t * (70 - 20 * t)))
        return 1.5 * eased * min(1, max(0, emphasis))
    }

}

struct LyricsLine: Equatable {
    var start: TimeInterval
    var end: TimeInterval?
    var text: String
    var words: [LyricsWord] = []
    /// Apple timing spans can contain several characters; interpolate whole composed characters within each span.
    var characterTimings: [LyricsWord] {
        var ranges: [NSRange] = []
        for index in text.indices where !text[index].isWhitespace {
            ranges.append(NSRange(index..<text.index(after: index), in: text))
        }
        return words.flatMap { word -> [LyricsWord] in
            let characters = ranges.filter { NSIntersectionRange($0, word.range).length > 0 }
            guard !characters.isEmpty else { return [] }
            let duration = max(0.01, word.end - word.start) / Double(characters.count)
            return characters.enumerated().map { offset, range in
                LyricsWord(start: word.start + Double(offset) * duration,
                           end: word.start + Double(offset + 1) * duration, range: range)
            }
        }
    }
}

struct LyricsWindow: Equatable {
    var previous = ""
    var current = ""
    var next = ""
}

struct LyricsDocument: Equatable {
    var lines: [LyricsLine]
    var plainText: String
    var songwriters: [String] = []

    func index(at time: TimeInterval) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
    func position(at time: TimeInterval) -> Double { LyricsTimeline(document: self).position(at: time) }
    func window(at time: TimeInterval) -> LyricsWindow {
        guard !lines.isEmpty else { return LyricsWindow(current: plainText) }
        let i = index(at: time)
        return LyricsWindow(previous: i > 0 ? lines[i - 1].text : "", current: lines[i].text,
                            next: i + 1 < lines.count ? lines[i + 1].text : "")
    }
}

enum LyricsSlotKind: Equatable {
    case line(Int)
    case waiting
    case credits
}
struct LyricsSlot: Equatable {
    var kind: LyricsSlotKind
    var start: Double
    var end: Double?
}

/// A long rest is a stationary countdown row between the finished and upcoming sentence.
struct LyricsTimeline {
    let slots: [LyricsSlot]
    init(document: LyricsDocument, duration: Double? = nil) {
        var result: [LyricsSlot] = []
        if let first = document.lines.first, first.start >= 5 {
            result.append(LyricsSlot(kind: .waiting, start: 0, end: first.start))
        }
        for (index, line) in document.lines.enumerated() {
            result.append(LyricsSlot(kind: .line(index), start: line.start, end: line.end))
            if index + 1 < document.lines.count, let end = line.end,
               document.lines[index + 1].start - end >= 5 {
                result.append(LyricsSlot(kind: .waiting, start: end, end: document.lines[index + 1].start))
            }
        }
        if let last = document.lines.last {
            let finish = last.end ?? duration.flatMap { $0 > last.start ? $0 : nil } ?? (last.start + 5)
            let creditStart = duration.flatMap { $0 >= finish ? min($0, finish + 0.8) : nil } ?? (finish + 0.8)
            result.append(LyricsSlot(kind: .credits, start: creditStart, end: nil))
        }
        slots = result
    }
    func index(at time: Double) -> Int {
        var low = 0, high = slots.count
        while low < high {
            let mid = (low + high) / 2
            if slots[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
    func position(at time: Double) -> Double {
        guard !slots.isEmpty else { return 0 }
        let i = index(at: time)
        guard i + 1 < slots.count, case .line = slots[i].kind, case .line = slots[i + 1].kind,
              let end = slots[i].end, slots[i + 1].start - end > 0.3, time > end else { return Double(i) }
        let f = min(1, max(0, (time - end) / (slots[i + 1].start - end)))
        return Double(i) + f * f * (3 - 2 * f)
    }
    static func dotBrightness(at time: Double, start: Double, end: Double) -> [Double] {
        let phase = min(1, max(0, (time - start) / max(0.01, end - start))) * 3
        return (0..<3).map { index in
            let t = min(1, max(0, phase - Double(index)))
            return 0.18 + 0.72 * t * t * (3 - 2 * t)
        }
    }
}

enum LyricsState: Equatable {
    case idle, loading, missing, failed
    case document(LyricsDocument)
}

/// TTML is parsed locally; XML entities never trigger network or filesystem reads.
enum AppleLyricsParser {
    static func time(_ raw: String?) -> TimeInterval? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Double?
        if text.hasSuffix("ms") { value = Double(text.dropLast(2)).map { $0 / 1000 } }
        else if text.hasSuffix("s") { value = Double(text.dropLast()) }
        else {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { return nil }
            var seconds = 0.0
            for part in parts {
                guard let number = Double(part), number.isFinite, number >= 0 else { return nil }
                seconds = seconds * 60 + number
            }
            value = seconds
        }
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func parse(_ text: String) -> LyricsDocument? {
        guard let data = text.data(using: .utf8), data.count <= 8 * 1024 * 1024 else { return nil }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.sawTTML else { return nil }
        let sorted = delegate.lines.sorted { $0.start < $1.start }
        var lines: [LyricsLine] = []
        for line in sorted {
            if let last = lines.last, last.start == line.start {
                let offset = (last.text as NSString).length + 3
                lines[lines.count - 1].text += " · " + line.text
                lines[lines.count - 1].words += line.words.map {
                    LyricsWord(start: $0.start, end: $0.end, range: NSRange(location: $0.range.location + offset, length: $0.range.length))
                }
                lines[lines.count - 1].end = [last.end, line.end].compactMap { $0 }.max()
            } else { lines.append(line) }
        }
        for i in lines.indices where lines[i].end == nil && i + 1 < lines.count { lines[i].end = lines[i + 1].start }
        let plain = delegate.plain.joined(separator: "\n")
        guard !plain.isEmpty else { return nil }
        return LyricsDocument(lines: lines, plainText: plain, songwriters: delegate.songwriters)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct TimedSpan {
            var depth: Int
            var offset: Int
            var start: Double
            var end: Double?
            var hasTimedChild = false
        }
        struct Word {
            var start: Double
            var end: Double?
            var range: NSRange
        }
        var sawTTML = false
        var lines: [LyricsLine] = []
        var plain: [String] = []
        var songwriters: [String] = []
        private var writerDepth: Int?
        private var writerText = ""
        private var inBody = false, inLine = false, pendingSpace = false
        private var depth = 0
        private var text = ""
        private var start: Double?, end: Double?
        private var spans: [TimedSpan] = []
        private var words: [Word] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String]) {
            depth += 1
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if name == "tt" { sawTTML = true }
            if name == "body" { inBody = true }
            if name == "songwriter", !inBody { writerDepth = depth; writerText = "" }
            guard inBody else { return }
            if name == "p" {
                inLine = true; text = ""; pendingSpace = false; spans = []; words = []
                start = AppleLyricsParser.time(attributes["begin"])
                end = AppleLyricsParser.time(attributes["end"])
                if end == nil, let start, let duration = AppleLyricsParser.time(attributes["dur"]) { end = start + duration }
            } else if inLine && name == "span", let t = AppleLyricsParser.time(attributes["begin"]) {
                if !spans.isEmpty { spans[spans.count - 1].hasTimedChild = true }
                let spanEnd = AppleLyricsParser.time(attributes["end"])
                    ?? AppleLyricsParser.time(attributes["dur"]).map { t + $0 }
                spans.append(TimedSpan(depth: depth, offset: (text as NSString).length, start: t, end: spanEnd))
                start = min(start ?? t, t)
                if let spanEnd { end = max(end ?? spanEnd, spanEnd) }
            } else if inLine && name == "br" { append(" ") }
        }
        private func append(_ value: String) {
            for character in value {
                if character.isWhitespace { if !text.isEmpty { pendingSpace = true } }
                else {
                    if pendingSpace { text += " "; pendingSpace = false }
                    text.append(character)
                }
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inLine { append(string) }
            if writerDepth != nil { writerText += string }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if inLine, let string = String(data: CDATABlock, encoding: .utf8) { append(string) }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            defer { depth -= 1 }
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if name == "songwriter", writerDepth == depth {
                let name = writerText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !name.isEmpty && !songwriters.contains(name) { songwriters.append(name) }
                writerDepth = nil
            }
            if name == "span", let span = spans.last, span.depth == depth {
                spans.removeLast()
                if !span.hasTimedChild {
                    let raw = (text as NSString).substring(from: span.offset) as NSString
                    let trimmed = (raw as String).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let range = raw.range(of: trimmed)
                        words.append(Word(start: span.start, end: span.end,
                                          range: NSRange(location: span.offset + range.location, length: range.length)))
                    }
                }
            }
            if name == "p", inLine {
                if !text.isEmpty {
                    plain.append(text)
                    if let start {
                        let timedWords = words.enumerated().map { index, word in
                            let next = index + 1 < words.count ? words[index + 1].start : nil
                            let wordEnd = word.end ?? next ?? end ?? (word.start + 0.2)
                            return LyricsWord(start: word.start, end: max(word.start + 0.01, wordEnd), range: word.range)
                        }
                        lines.append(LyricsLine(start: start, end: end.flatMap { $0 > start ? $0 : nil }, text: text, words: timedWords))
                    }
                }
                inLine = false
            }
            if name == "body" { inBody = false }
        }
    }

}

protocol LyricsProviding {
    func lookup(_ track: LyricsTrack) -> LyricsState
    /// `isCancelled` is polled between cache files so an obsolete lookup stops reading as soon as the track changes.
    func lookup(_ track: LyricsTrack, isCancelled: () -> Bool) -> LyricsState
}
extension LyricsProviding {
    func lookup(_ track: LyricsTrack, isCancelled: () -> Bool) -> LyricsState { lookup(track) }
}

/// Music.app owns the cache. Only read its catalog responses; never use credentials or issue lyrics requests.
final class AppleMusicLyricsProvider: LyricsProviding {
    let root: URL
    private let maximumBytes = 8 * 1024 * 1024
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.apple.Music")) {
        self.root = root
    }
    func lookup(_ track: LyricsTrack) -> LyricsState { lookup(track, isCancelled: { false }) }
    func lookup(_ track: LyricsTrack, isCancelled: () -> Bool) -> LyricsState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return .missing }
        guard fm.isReadableFile(atPath: root.path) else { return .failed }
        var best: (score: Int, document: LyricsDocument)?
        var invalidLyrics = false
        var seen = Set<String>()
        func consider(_ data: Data) {
            guard data.count <= maximumBytes,
                  let first = data.first(where: { ![UInt8(32), 9, 10, 13].contains($0) }), first == 123,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let songs = (object["data"] as? [[String: Any]] ?? []) + (object["included"] as? [[String: Any]] ?? [])
            for song in songs {
                guard let score = Self.match(song, track: track), score > (best?.score ?? -1),
                      let relationships = song["relationships"] as? [String: Any],
                      let lyrics = relationships["syllable-lyrics"] as? [String: Any],
                      let entries = lyrics["data"] as? [[String: Any]] else { continue }
                for entry in entries {
                    guard let attributes = entry["attributes"] as? [String: Any],
                          let ttml = Self.ttml(attributes["ttmlLocalizations"]) else { continue }
                    guard let document = AppleLyricsParser.parse(ttml) else { invalidLyrics = true; continue }
                    best = (score, document)
                    break
                }
            }
        }
        func readFile(_ name: String) {
            // Cache filenames must not escape fsCachedData.
            guard name == (name as NSString).lastPathComponent, !name.isEmpty, seen.insert(name).inserted else { return }
            let url = root.appendingPathComponent("fsCachedData").appendingPathComponent(name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
            consider(data)
        }
        let dbURL = root.appendingPathComponent("Cache.db")
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db {
            sqlite3_busy_timeout(db, 100)
            let sql = "SELECT d.isDataOnFS,d.receiver_data FROM cfurl_cache_response r JOIN cfurl_cache_receiver_data d ON r.entry_ID=d.entry_ID WHERE r.request_key LIKE '%syllable-lyrics%' ORDER BY r.time_stamp DESC LIMIT 160"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if isCancelled() { break }
                    if sqlite3_column_int(statement, 0) != 0 {
                        if let name = sqlite3_column_text(statement, 1) { readFile(String(cString: name)) }
                    } else {
                        let count = Int(sqlite3_column_bytes(statement, 1))
                        if count > 0, count <= maximumBytes, let bytes = sqlite3_column_blob(statement, 1) { consider(Data(bytes: bytes, count: count)) }
                    }
                    if best?.score == 300 { break }
                }
            }
            sqlite3_finalize(statement)
        }
        if let db { sqlite3_close(db) }
        if best?.score != 300, !isCancelled() {
            let directory = root.appendingPathComponent("fsCachedData")
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
            let recent = files.compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }.prefix(160)
            for (url, _) in recent {
                if isCancelled() { break }
                readFile(url.lastPathComponent)
                if best?.score == 300 { break }
            }
        }
        return best.map { .document($0.document) } ?? (invalidLyrics ? .failed : .missing)
    }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func match(_ song: [String: Any], track: LyricsTrack) -> Int? {
        if !track.catalogID.isEmpty { return String(describing: song["id"] ?? "") == track.catalogID ? 300 : nil }
        // Title, artist and duration identify a recording; the album string is localised or suffixed too often to be required.
        guard !track.title.isEmpty, !track.artist.isEmpty, track.duration > 0,
              let attributes = song["attributes"] as? [String: Any],
              let title = attributes["name"] as? String, let artist = attributes["artistName"] as? String,
              normalized(title) == normalized(track.title), normalized(artist) == normalized(track.artist),
              let duration = attributes["durationInMillis"] as? NSNumber,
              abs(duration.doubleValue / 1000 - Double(track.duration)) <= 2 else { return nil }
        if !track.album.isEmpty, let album = attributes["albumName"] as? String, normalized(album) == normalized(track.album) { return 200 }
        return 150
    }
    private static func ttml(_ value: Any?, depth: Int = 0) -> String? {
        guard depth < 4 else { return nil }
        if let text = value as? String, text.contains("<") { return text }
        if let dictionary = value as? [String: Any] {
            let preferred = ["original", "ttml"] + Locale.preferredLanguages
            for key in preferred { if let result = ttml(dictionary[key], depth: depth + 1) { return result } }
            for key in dictionary.keys.sorted() { if let result = ttml(dictionary[key], depth: depth + 1) { return result } }
        }
        return nil
    }
}

/// Owned by the main thread; the serial worker is the only user of the cache provider.
final class LyricsController {
    private let provider: LyricsProviding
    private let queue = DispatchQueue(label: "ni.lyrics", qos: .utility)
    private let lock = NSLock()
    private var workerRequest = UUID()           // read by the worker to drop obsolete lookups
    private(set) var track: LyricsTrack?
    /// Bumped whenever `state` is replaced, so views can compare a number instead of a whole document.
    private(set) var version = 0
    private(set) var state: LyricsState = .idle { didSet { version += 1 } }
    private(set) var requestID = UUID() {
        didSet { lock.lock(); workerRequest = requestID; lock.unlock() }
    }
    private(set) var loading = false
    private var nextScan = Date.distantPast
    private var lastScanStart = Date.distantPast
    private var misses = 0
    /// A missing or unreadable cache is retried with a growing delay instead of every few seconds.
    static let backoff: [TimeInterval] = [10, 30, 60]
    private var cache: [LyricsTrack: LyricsDocument] = [:]
    var onChange: (() -> Void)?
    init(provider: LyricsProviding = AppleMusicLyricsProvider()) { self.provider = provider }
    func select(_ track: LyricsTrack?) {
        guard self.track != track else { return }
        suspend()
        self.track = track
        misses = 0; nextScan = .distantPast
        state = track.flatMap { cache[$0] }.map { .document($0) } ?? .idle
    }
    /// Stops the current lookup. The back-off survives, so closing and reopening the pane cannot defeat it.
    func suspend() {
        requestID = UUID(); loading = false
        if state == .loading { state = .idle }
    }
    /// The user asked for lyrics: look again at once.
    func requestNow() { misses = 0; nextScan = .distantPast }
    func refreshIfNeeded(now: Date = Date()) {
        guard let track, !loading, now >= nextScan else { return }
        if case .document = state { return }
        loading = true; lastScanStart = now
        if state == .idle { state = .loading }
        let id = UUID(); requestID = id
        queue.async { [weak self, provider, lock] in
            func current() -> Bool { guard let self else { return false }; lock.lock(); defer { lock.unlock() }; return self.workerRequest == id }
            guard current() else { return }       // skipped while it waited behind an older lookup
            let result = provider.lookup(track, isCancelled: { !current() })
            DispatchQueue.main.async { self?.accept(result, for: track, request: id) }
        }
    }
    func accept(_ result: LyricsState, for track: LyricsTrack, request: UUID) {
        guard self.track == track, requestID == request else { return }
        loading = false; state = result
        if case .document(let document) = result {
            misses = 0
            if cache.count >= 40 { cache.removeAll(keepingCapacity: true) }
            cache[track] = document
        } else {
            nextScan = lastScanStart.addingTimeInterval(Self.backoff[min(misses, Self.backoff.count - 1)])
            misses += 1
        }
        onChange?()
    }
}
