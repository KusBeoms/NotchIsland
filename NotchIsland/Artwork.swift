import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Artwork (album art via Apple's public iTunes lookup, keyed by the track's store id)

/// Pick a representative album hue rather than averaging complementary colours into grey.
/// Neutral margins don't overwhelm coloured artwork; monochrome covers stay monochrome.
func playbackColor(from img: NSImage) -> NSColor {
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return accent }
    let side = 48, binCount = 24
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let ctx = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return true
    }
    guard rendered else { return accent }
    struct Sample {
        var weight: CGFloat = 0
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        mutating func add(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, weight w: CGFloat) {
            weight += w; red += r * w; green += g * w; blue += b * w
        }
    }
    var bins = [Sample](repeating: Sample(), count: binCount)
    var neutral = Sample()
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let alpha = CGFloat(pixels[i + 3]) / 255
        guard alpha >= 0.1 else { continue }
        // CGContext returns premultiplied RGBA: recover the original colour first.
        let r = CGFloat(pixels[i]) / (255 * alpha)
        let g = CGFloat(pixels[i + 1]) / (255 * alpha)
        let b = CGFloat(pixels[i + 2]) / (255 * alpha)
        neutral.add(r, g, b, weight: alpha)
        let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, unused: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &unused)
        guard saturation >= 0.18, brightness >= 0.12 else { continue }
        let bin = min(binCount - 1, Int(hue * CGFloat(binCount)))
        bins[bin].add(r, g, b, weight: alpha * saturation * brightness)
    }
    guard neutral.weight > 0 else { return accent }
    var sample = neutral
    if let peak = bins.indices.max(by: { bins[$0].weight < bins[$1].weight }), bins[peak].weight > 0 {
        // Merge neighbouring hues so gradients and the red hue wrap stay coherent.
        sample = Sample()
        for offset in -1...1 {
            let bin = bins[(peak + offset + binCount) % binCount]
            sample.weight += bin.weight
            sample.red += bin.red; sample.green += bin.green; sample.blue += bin.blue
        }
    }
    let color = NSColor(srgbRed: sample.red / sample.weight, green: sample.green / sample.weight,
                        blue: sample.blue / sample.weight, alpha: 1)
    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, unused: CGFloat = 0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &unused)
    return NSColor(hue: hue, saturation: saturation, brightness: max(brightness, 0.85), alpha: 1)
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

