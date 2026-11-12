import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Artwork (album art via Apple's public iTunes lookup, keyed by the track's store id)

func averageColor(_ img: NSImage) -> NSColor {
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return accent }
    var px = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return accent }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return NSColor(hue: h, saturation: max(s, 0.45), brightness: max(b, 0.9), alpha: 1)   // keep it readable on black
}

private let artworkScript = """
ObjC.import("Foundation");
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
var out = "";
var req = $.NSClassFromString("MRNowPlayingRequest");
if (req) {
  var item = req.localNowPlayingItem;
  if (item && !item.isNil()) {
    try {
      var d = item.nowPlayingInfo.objectForKey("kMRMediaRemoteNowPlayingInfoArtworkData");
      if (d && !d.isNil()) out = ObjC.unwrap(d.base64EncodedStringWithOptions(0));
    } catch (e) {}
  }
}
out;
"""

/// The cover art of whatever is playing, as the player itself hands it over (no store id needed).
func queryArtworkData() -> NSImage? {
    let s = runJXA(artworkScript)
    guard !s.isEmpty, let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return nil }
    return NSImage(data: d)
}

func fetchArtwork(storeID: String, completion: @escaping (NSImage?) -> Void) {
    let region = Locale.current.region?.identifier ?? "US"
    guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(storeID)&country=\(region)") else { completion(nil); return }
    var req = URLRequest(url: url); req.timeoutInterval = 8
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let data = data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = (j["results"] as? [[String: Any]])?.first,
              let u100 = r["artworkUrl100"] as? String,
              let imgURL = URL(string: u100.replacingOccurrences(of: "100x100bb", with: "300x300bb")) else { completion(nil); return }
        var r2 = URLRequest(url: imgURL); r2.timeoutInterval = 8
        URLSession.shared.dataTask(with: r2) { d2, _, _ in completion(d2.flatMap { NSImage(data: $0) }) }.resume()
    }.resume()
}

