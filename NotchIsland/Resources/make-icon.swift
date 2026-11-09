import AppKit
import Foundation

let directory = CommandLine.arguments[1]
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, pixels) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 220, yRadius: 220)
    NSGradient(starting: NSColor(calibratedRed: 0.23, green: 0.26, blue: 0.32, alpha: 1),
               ending: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1))!.draw(in: background, angle: 90)
    let island = NSBezierPath(roundedRect: NSRect(x: 168, y: 369, width: 688, height: 286), xRadius: 143, yRadius: 143)
    NSColor.black.setFill(); island.fill()
    let heights: [CGFloat] = [54, 100, 150, 112, 68]
    for (index, height) in heights.enumerated() {
        let bar = NSBezierPath(roundedRect: NSRect(x: 409 + CGFloat(index) * 44, y: 512 - height / 2, width: 24, height: height), xRadius: 12, yRadius: 12)
        NSColor(calibratedRed: 1, green: 0.62, blue: 0.04, alpha: 1).setFill(); bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
}
