import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Now playing (system-wide: Music, Spotify, browsers, Podcasts ...)
//
// Since macOS 15.4 only Apple-signed processes may talk to MediaRemote, so an app cannot call it directly.
// /usr/bin/osascript is Apple-signed, so the lookup and the transport commands run inside it (JXA).

struct Media {
    struct TrackID: Equatable {
        var title: String
        var artist: String
        var storeID: String
        var bundleID: String
    }
    var trackID: TrackID { TrackID(title: title, artist: artist, storeID: storeID, bundleID: bundleID) }
    var title: String
    var artist: String
    var playing: Bool
    var duration: TimeInterval
    var elapsed: TimeInterval      // position at `readAt`
    var readAt: Date
    var storeID: String
    var bundleID: String = ""          // the app that is playing (a browser for web video)
    var album: String = ""
    var elapsedNow: TimeInterval { elapsed(at: Date()) }
    func elapsed(at now: Date) -> TimeInterval {
        let e = elapsed + (playing ? now.timeIntervalSince(readAt) : 0)
        return duration > 0 ? min(e, duration) : e
    }
    /// A small presentation lead offsets drawing latency without advancing paused or scrubbed lyrics.
    func lyricsPosition(at now: Date = Date(), seekFraction: CGFloat? = nil) -> TimeInterval {
        if let seekFraction { return max(0, min(1, Double(seekFraction))) * max(0, duration) }
        let position = max(0, elapsed(at: now) + (playing ? 0.06 : 0))
        return duration > 0 ? min(position, duration) : position
    }
}

private let nowPlayingScript = """
ObjC.import("Foundation");
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
var out = "NONE";
var req = $.NSClassFromString("MRNowPlayingRequest");
if (req) {
  var item = req.localNowPlayingItem;
  if (item && !item.isNil()) {
    var info = item.nowPlayingInfo;
    var g = function (k) { try { return ObjC.unwrap(info.objectForKey(k)); } catch (e) { return null; } };
    var title = g("kMRMediaRemoteNowPlayingInfoTitle");
    var appBundle = "";
    try {
      var client = req.localNowPlayingPlayerPath.client;
      appBundle = ObjC.unwrap(client.parentApplicationBundleIdentifier) || ObjC.unwrap(client.bundleIdentifier) || "";
    } catch (e) {}
    if (title) {
      var pos = null;
      var sampledAt = Date.now() / 1000;
      try { pos = item.metadata.calculatedPlaybackPosition; } catch (e) {}
      out = JSON.stringify({
        title: title,
        artist: g("kMRMediaRemoteNowPlayingInfoArtist") || "",
        album: g("kMRMediaRemoteNowPlayingInfoAlbum") || "",
        rate: g("kMRMediaRemoteNowPlayingInfoPlaybackRate") || 0,
        duration: g("kMRMediaRemoteNowPlayingInfoDuration") || 0,
        elapsed: (pos !== null && pos !== undefined) ? pos : (g("kMRMediaRemoteNowPlayingInfoElapsedTime") || 0),
        id: String(g("kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier") || ""),
        app: appBundle,
        sampledAt: sampledAt
      });
    }
  }
}
out;
"""

/// Runs a tool with a watchdog and returns its stdout.
func runTool(_ path: String, _ args: [String], timeout: TimeInterval = 4) -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return Data() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }   // watchdog
    let data = out.fileHandleForReading.readDataToEndOfFile()   // read first, then wait (avoids pipe-full deadlock)
    p.waitUntilExit()
    return data
}

/// Runs osascript (JXA) and returns trimmed stdout.
func runJXA(_ script: String) -> String {
    String(data: runTool("/usr/bin/osascript", ["-l", "JavaScript", "-e", script]), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

enum PollResult { case failed, nothing, media(Media) }

func queryNowPlaying() -> PollResult {
    let startedAt = Date()
    let s = runJXA(nowPlayingScript)
    return parseNowPlaying(s, queryStartedAt: startedAt, receivedAt: Date())
}

func parseNowPlaying(_ s: String, queryStartedAt: Date, receivedAt: Date) -> PollResult {
    if s.isEmpty { return .failed }                  // timed out / crashed: say nothing about the state
    if s == "NONE" { return .nothing }
    guard let d = s.data(using: .utf8),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let title = j["title"] as? String else { return .failed }
    func num(_ k: String) -> Double { (j[k] as? NSNumber)?.doubleValue ?? 0 }
    let timestamp = num("sampledAt")
    let sampleIsValid = timestamp.isFinite && timestamp >= queryStartedAt.timeIntervalSince1970
        && timestamp <= receivedAt.timeIntervalSince1970 + 0.05
    let readAt = sampleIsValid ? Date(timeIntervalSince1970: timestamp) : receivedAt
    return .media(Media(title: title, artist: (j["artist"] as? String) ?? "", playing: num("rate") > 0,
                        duration: num("duration"), elapsed: num("elapsed"), readAt: readAt, storeID: (j["id"] as? String) ?? "",
                        bundleID: (j["app"] as? String) ?? "", album: (j["album"] as? String) ?? ""))
}

/// MediaRemote command ids: 0 play, 1 pause, 2 toggle play/pause, 4 next, 5 previous.
private let mediaCommandQueue = DispatchQueue(label: "ni.mediacmd", qos: .userInitiated)   // serial: quick taps never run osascript in parallel
func sendMediaCommand(_ cmd: Int, completion: (() -> Void)? = nil) {
    mediaCommandQueue.async {
        defer { if let completion { DispatchQueue.main.async(execute: completion) } }
        _ = runJXA("""
        ObjC.import("Foundation");
        $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
        $.NSClassFromString("MRNowPlayingController").localRouteController.sendCommandOptionsCompletion(\(cmd), $(), null);
        delay(0.2);
        "";
        """)
    }
}

/// Jumps the playing track to `seconds` (MediaRemote command 24, "seek to playback position").
func sendMediaSeek(_ seconds: Double) {
    mediaCommandQueue.async {
        _ = runJXA("""
        ObjC.import("Foundation");
        $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
        $.NSClassFromString("MRNowPlayingController").localRouteController.sendCommandOptionsCompletion(24, $({kMRMediaRemoteOptionPlaybackPosition: \(seconds)}), null);
        delay(0.2);
        "";
        """)
    }
}


/// Fallback when MediaRemote does not reach a player: the same play/pause media key the keyboard sends.
func postPlayPauseKey() {
    for down in [true, false] {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
        let data1 = (16 << 16) | ((down ? 0xA : 0xB) << 8)       // NX_KEYTYPE_PLAY = 16
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                           context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
    }
}
