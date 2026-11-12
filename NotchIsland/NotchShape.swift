import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Notch silhouette
//
// Like the hardware notch the shape is wider at the very top than below it: the top corners flare OUT into
// the top edge of the screen (concave "ears", radius `earRadius`) and the bottom corners are convex.
// Idle island = 6pt ears / 14pt bottom corners (the notch itself); both ease up as it grows into a card.
func earRadius(_ h: CGFloat) -> CGFloat { min(18, max(6, 6 + (h - 40) * 0.2)) }
func bottomRadius(_ h: CGFloat) -> CGFloat { min(26, max(14, 14 + (h - 40) * 0.18)) }

func notchPath(_ w: CGFloat, _ h: CGFloat, earL: Bool = true, earR: Bool = true) -> CGPath {
    let t = earRadius(h)
    let tl = earL ? t : 0, tr = earR ? t : 0
    let b = max(0, min(bottomRadius(h), h - t, (w - tl - tr) / 2))
    let p = CGMutablePath()                                     // y grows upward; the top edge is y = h
    p.move(to: CGPoint(x: 0, y: h))
    p.addLine(to: CGPoint(x: w, y: h))
    if earR { p.addArc(center: CGPoint(x: w, y: h - t), radius: t, startAngle: .pi / 2, endAngle: .pi, clockwise: false) }   // right ear
    p.addLine(to: CGPoint(x: w - tr, y: b))
    p.addArc(center: CGPoint(x: w - tr - b, y: b), radius: b, startAngle: 0, endAngle: -.pi / 2, clockwise: true)           // bottom right
    p.addLine(to: CGPoint(x: tl + b, y: 0))
    p.addArc(center: CGPoint(x: tl + b, y: b), radius: b, startAngle: -.pi / 2, endAngle: -.pi, clockwise: true)            // bottom left
    p.addLine(to: CGPoint(x: tl, y: earL ? h - t : h))
    if earL { p.addArc(center: CGPoint(x: 0, y: h - t), radius: t, startAngle: 0, endAngle: .pi / 2, clockwise: false) }    // left ear
    p.closeSubpath()
    return p
}

