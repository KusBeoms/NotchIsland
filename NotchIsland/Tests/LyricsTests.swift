import Foundation
import SQLite3

private final class FixtureProvider: LyricsProviding {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func lookup(_ track: LyricsTrack) -> LyricsState {
        lock.lock(); calls += 1; lock.unlock()
        return .missing
    }
}

@main
struct LyricsTests {
    static func main() throws {
        let expanding = LyricsWidthTransition(from: 332, to: 632, start: 10)
        let shrinking = LyricsWidthTransition(from: 632, to: 332, start: 10)
        let samples = (0...18).map { expanding.value(at: 10 + Double($0) / 100) }
        assert(samples.first == 332 && abs(samples.last! - 632) < 0.0001)
        assert(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
        assert((0...18).allSatisfy { (332...632).contains(shrinking.value(at: 10 + Double($0) / 100)) })
        assert(expanding.finished(at: 10.2))
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"><head><metadata>Not a lyric</metadata></head><body><div>
        <p begin="00:01.000" end="3s"><span begin="1s" end="2s">First </span><span begin="2s" end="3s">line</span></p>
        <p begin="5s" dur="2s">Second &amp; final<br/>line</p>
        </div></body></tt>
        """
        let document = AppleLyricsParser.parse(ttml)!
        assert(document.lines.map { $0.text } == ["First line", "Second & final line"])
        assert(document.lines[0].start == 1 && document.lines[0].end == 3)
        assert(document.lines[1].start == 5 && document.lines[1].end == 7)
        assert(document.lines[0].words == [LyricsWord(start: 1, end: 2, range: NSRange(location: 0, length: 5)),
                                            LyricsWord(start: 2, end: 3, range: NSRange(location: 6, length: 4))])
        assert(document.lines[0].words[0].progress(at: 1.5) == 0.5)
        assert(document.lines[0].words[1].progress(at: 1.5) == 0)
        assert(document.lines[0].words[1].progress(at: 4) == 1)
        let liftedWord = document.lines[0].words[0]
        assert(liftedWord.lift(at: 1, emphasis: 1, reduceMotion: false) == 0)
        let risingLift = liftedWord.lift(at: 1.03, emphasis: 1, reduceMotion: false)
        let spokenLift = liftedWord.lift(at: 1.5, emphasis: 1, reduceMotion: false)
        assert(risingLift > 0 && risingLift < spokenLift)
        assert(abs(spokenLift - 1.5) < 0.00001)
        assert(liftedWord.lift(at: 2.5, emphasis: 1, reduceMotion: false) == spokenLift)
        assert(liftedWord.lift(at: 1.5, emphasis: 0, reduceMotion: false) == 0)
        assert(liftedWord.lift(at: 1.5, emphasis: 1, reduceMotion: true) == 0)
        let composedText = "가😀e\u{301}"
        let composedLine = LyricsLine(start: 0, end: 0.9, text: composedText,
                                     words: [LyricsWord(start: 0, end: 0.9, range: NSRange(location: 0, length: (composedText as NSString).length))])
        let characters = composedLine.characterTimings
        assert(characters.count == 3)
        assert(characters.map(\.range) == [NSRange(location: 0, length: 1), NSRange(location: 1, length: 2), NSRange(location: 3, length: 2)])
        assert(characters[0].start < characters[1].start && characters[1].start < characters[2].start)
        assert(characters[0].lift(at: 0.15, emphasis: 1, reduceMotion: false, minimumRiseDuration: 0.1) > 0)
        assert(characters[1].lift(at: 0.15, emphasis: 1, reduceMotion: false, minimumRiseDuration: 0.1) == 0)
        let quickCharacter = LyricsWord(start: 0, end: 0.08, range: NSRange(location: 0, length: 1))
        let gentleRise = quickCharacter.lift(at: 0.08, emphasis: 1, reduceMotion: false, minimumRiseDuration: 0.24)
        assert(gentleRise > 0 && gentleRise < 0.75) // Short syllables still rise gradually after their timestamp ends.
        assert(quickCharacter.lift(at: 0.24, emphasis: 1, reduceMotion: false, minimumRiseDuration: 0.24) == 1.5)
        let softStart = quickCharacter.lift(at: 0.032, emphasis: 1, reduceMotion: false, minimumRiseDuration: 0.32) / 1.5
        let softEnd = quickCharacter.lift(at: 0.288, emphasis: 1, reduceMotion: false, minimumRiseDuration: 0.32) / 1.5
        assert(softStart < 0.005 && softEnd > 0.995)
        assert(abs(softStart + softEnd - 1) < 0.00001)


        assert(document.window(at: 0).current == "First line")
        assert(document.window(at: 1).current == "First line")
        assert(document.window(at: 4) == LyricsWindow(current: "First line", next: "Second & final line"))
        assert(document.position(at: 3) == 0 && document.position(at: 4) == 0.5 && document.position(at: 5) == 1)
        assert(document.position(at: 3.5) < document.position(at: 4.5))
        assert(document.window(at: 5).current == "Second & final line")
        assert(document.window(at: 8).current == "Second & final line")
        assert(document.window(at: 2).current == "First line") // Backward seek.
        assert(AppleLyricsParser.time("1500ms") == 1.5)
        assert(AppleLyricsParser.time("01:02:03.5") == 3723.5)
        for invalid in ["-1s", "nan", "inf", "bad", "1::2"] { assert(AppleLyricsParser.time(invalid) == nil) }
        assert(AppleLyricsParser.parse("<tt><body><p>broken") == nil)
        assert(AppleLyricsParser.parse("<other><body><p>wrong root</p></body></other>") == nil)
        assert(AppleLyricsParser.parse("<tt><body><p>Untimed lyric</p></body></tt>")?.lines.isEmpty == true)
        let spansOnly = AppleLyricsParser.parse("<tt><body><p><span begin='2s' end='4s'>Timed</span></p></body></tt>")!
        assert(spansOnly.lines.first?.start == 2)
        let nested = AppleLyricsParser.parse("<tt><body><p><span begin='1s' end='3s'><span begin='1s' end='2s'>한 </span><span begin='2s' end='3s'>😀글</span></span></p></body></tt>")!
        assert(nested.lines[0].text == "한 😀글" && nested.lines[0].words.count == 2)
        assert(nested.lines[0].words[1].range == NSRange(location: 2, length: 3))
        let cdata = AppleLyricsParser.parse("<tt><body><p begin='1s'><![CDATA[한 줄]]></p></body></tt>")!
        assert(cdata.lines[0].text == "한 줄")
        let sameStart = AppleLyricsParser.parse("<tt><body><p begin='1s'>Voice A</p><p begin='1s'>Voice B</p><p begin='3s'>Next</p></body></tt>")!
        assert(sameStart.lines.count == 2 && sameStart.lines[0].end == 3)
        let external = "<!DOCTYPE tt [<!ENTITY external SYSTEM 'file:///nonexistent/lyrics-secret'>]><tt><body><p>&external;</p></body></tt>"
        assert(AppleLyricsParser.parse(external) == nil)

        let writers = AppleLyricsParser.parse("<tt><head><metadata><songwriters><songwriter>Choi Yu Ree</songwriter><songwriter>Choi Yu Ree</songwriter></songwriters></metadata></head><body><p begin='0s' end='1s'>A</p></body></tt>")!
        assert(writers.songwriters == ["Choi Yu Ree"])
        let noGap = LyricsDocument(lines: [LyricsLine(start: 0, end: 1, text: "A"), LyricsLine(start: 1, end: 2, text: "B")], plainText: "A B")
        let noGapTimeline = LyricsTimeline(document: noGap)
        assert(noGapTimeline.position(at: 0.9) == 0 && noGapTimeline.position(at: 1) == 1)
        var follower = LyricsScrollFollower()
        follower.reset(to: 0)
        for _ in 0..<60 {
            let before = follower.position
            follower.advance(toward: 1, deltaTime: 1.0 / 60)
            assert(follower.position > before && follower.position - before <= follower.maximumSpeed / 60 + 0.00001)
        }
        assert(follower.position > 0.999 && follower.position < 1)
        let longGap = LyricsDocument(lines: [LyricsLine(start: 0, end: 1, text: "A"), LyricsLine(start: 10, end: 11, text: "B")], plainText: "A B", songwriters: ["Writer"])
        let longTimeline = LyricsTimeline(document: longGap)
        assert(longTimeline.slots[1].kind == .waiting)
        assert(longTimeline.position(at: 2) == 1 && longTimeline.position(at: 9) == 1)
        assert(longTimeline.slots.last?.kind == .credits && longTimeline.position(at: 12) == 3)
        let dotsEarly = LyricsTimeline.dotBrightness(at: 2.5, start: 1, end: 10)
        let dotsMiddle = LyricsTimeline.dotBrightness(at: 5.5, start: 1, end: 10)
        assert(dotsEarly[0] > dotsEarly[1] && dotsEarly[1] == dotsEarly[2])
        assert(dotsMiddle[0] > dotsMiddle[1] && dotsMiddle[1] > dotsMiddle[2])
        let intro = LyricsTimeline(document: LyricsDocument(lines: [LyricsLine(start: 10, end: 12, text: "Intro")], plainText: "Intro"))
        assert(intro.slots.first?.kind == .waiting && intro.position(at: 9) == 0)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = directory.appendingPathComponent("fsCachedData")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let track = LyricsTrack(title: "Fixture Song", artist: "Fixture Artist", album: "Fixture Album", duration: 120, catalogID: "123")
        let song: [String: Any] = ["id": "123", "attributes": ["name": track.title, "artistName": track.artist,
                         "albumName": track.album, "durationInMillis": 120000],
                         "relationships": ["syllable-lyrics": ["data": [["attributes": ["ttmlLocalizations": ttml]]]]]]
        let data = try JSONSerialization.data(withJSONObject: ["data": [song]])
        let provider = AppleMusicLyricsProvider(root: directory)
        assert(provider.lookup(track) == .missing)
        assert(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Cache.db").path))
        try data.write(to: files.appendingPathComponent("fixture"))
        assert(provider.lookup(track) == .document(document)) // Directory fallback with no database.
        var malformedSong = song
        malformedSong["relationships"] = ["syllable-lyrics": ["data": [["attributes": ["ttmlLocalizations": "<tt>broken"]]]]]
        try JSONSerialization.data(withJSONObject: ["data": [malformedSong]]).write(to: files.appendingPathComponent("fixture"))
        assert(provider.lookup(track) == .failed)
        try data.write(to: files.appendingPathComponent("fixture"))
        var other = track; other.catalogID = "999"
        assert(provider.lookup(other) == .missing)
        other = track; other.catalogID = ""; other.duration = 122
        assert(provider.lookup(other) == .document(document))
        other.duration = 123
        assert(provider.lookup(other) == .missing)
        other = track; other.catalogID = ""; other.album = "Fixture Album (Deluxe)"
        assert(provider.lookup(other) == .document(document)) // Album suffixes and localisations do not block a match.
        other.duration = 150
        assert(provider.lookup(other) == .missing)
        try Data("invalid database".utf8).write(to: directory.appendingPathComponent("Cache.db"))
        assert(provider.lookup(track) == .document(document)) // Schema failure still reads cached files.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Cache.db"))

        var db: OpaquePointer?
        assert(sqlite3_open(directory.appendingPathComponent("Cache.db").path, &db) == SQLITE_OK)
        assert(sqlite3_exec(db, "CREATE TABLE cfurl_cache_response(entry_ID INTEGER,request_key TEXT,time_stamp REAL); CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER,isDataOnFS INTEGER,receiver_data BLOB); INSERT INTO cfurl_cache_response VALUES(1,'fixture/syllable-lyrics',1);", nil, nil, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        assert(sqlite3_prepare_v2(db, "INSERT INTO cfurl_cache_receiver_data VALUES(1,0,?)", -1, &statement, nil) == SQLITE_OK)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        assert(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement); sqlite3_close(db)
        try FileManager.default.removeItem(at: files.appendingPathComponent("fixture"))
        assert(provider.lookup(track) == .document(document)) // Inline cache body.

        let fixture = FixtureProvider()
        let controller = LyricsController(provider: fixture)
        controller.select(track)
        let oldRequest = controller.requestID
        controller.select(other)
        controller.accept(.document(document), for: track, request: oldRequest)
        assert(controller.state == .idle) // Late result must not leak to the new song.
        controller.select(track)
        let now = Date()
        controller.refreshIfNeeded(now: now)
        controller.refreshIfNeeded(now: now.addingTimeInterval(1))
        waitUntil { !controller.loading }
        assert(controller.state == .missing && fixture.count == 1)
        controller.refreshIfNeeded(now: now.addingTimeInterval(9))
        assert(!controller.loading && fixture.count == 1) // Negative results back off.
        controller.suspend(); controller.refreshIfNeeded(now: now.addingTimeInterval(9))
        assert(!controller.loading && fixture.count == 1) // Closing and reopening does not defeat the back-off.
        controller.refreshIfNeeded(now: now.addingTimeInterval(10))
        waitUntil { !controller.loading }
        assert(fixture.count == 2)
        controller.refreshIfNeeded(now: now.addingTimeInterval(30))
        assert(!controller.loading && fixture.count == 2) // The second miss waits 30s.
        controller.requestNow()
        controller.refreshIfNeeded(now: now.addingTimeInterval(31))
        waitUntil { !controller.loading }
        assert(fixture.count == 3)
        controller.accept(.document(document), for: track, request: controller.requestID)
        controller.select(other); controller.select(track)
        assert(controller.state == .document(document)) // Reopening a cached song needs no new I/O.
        controller.refreshIfNeeded(now: now.addingTimeInterval(100))
        assert(!controller.loading && fixture.count == 3)
        controller.select(other)
        let closedRequest = controller.requestID
        controller.suspend()
        controller.accept(.document(document), for: other, request: closedRequest)
        assert(controller.state == .idle)
        print("Lyrics TTML, timing, cache matching, SQLite fallback and request lifecycle checks passed")
    }
    static func waitUntil(_ condition: () -> Bool) {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        assert(condition())
    }
}
