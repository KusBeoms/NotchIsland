import Foundation

@main
struct MediaTests {
    static func main() throws {
        let sample = Date(timeIntervalSince1970: 1000)
        let received = sample.addingTimeInterval(0.04)
        var json: [String: Any] = ["title": "Timing fixture", "artist": "Fixture", "rate": 1,
                                  "duration": 100, "elapsed": 10, "sampledAt": 1000]
        func parse(_ json: [String: Any]) throws -> Media {
            let data = try JSONSerialization.data(withJSONObject: json)
            guard case .media(let media) = parseNowPlaying(String(data: data, encoding: .utf8)!,
                                                          queryStartedAt: sample.addingTimeInterval(-0.1), receivedAt: received) else { fatalError() }
            return media
        }
        var media = try parse(json)
        assert(media.readAt == sample)
        assert(abs(media.elapsed(at: received) - 10.04) < 0.00001)
        assert(abs(media.lyricsPosition(at: received) - 10.10) < 0.00001)
        assert(media.lyricsPosition(at: received, seekFraction: 0.5) == 50)
        media.playing = false
        assert(media.lyricsPosition(at: received.addingTimeInterval(10)) == 10)
        media.playing = true; media.elapsed = 99.99
        assert(media.lyricsPosition(at: received) == 100)
        json.removeValue(forKey: "sampledAt")
        media = try parse(json)
        assert(media.readAt == received)
        json["sampledAt"] = 999
        media = try parse(json)
        assert(media.readAt == received)
        json["sampledAt"] = 2000
        media = try parse(json)
        assert(media.readAt == received)
        print("Playback sample timestamp, lyrics lead, pause, scrub and duration clamp checks passed")
    }
}
