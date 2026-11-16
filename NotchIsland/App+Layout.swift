import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Layout plan (which activity goes in which slot) and the island's geometry.

extension App {
    // MARK: layout plan: which activity goes where

    struct Plan: Equatable {
        var left: ActKind?
        var right: ActKind?
        var rightDetail = false         // right slot shows the detail of the same activity (single activity)
        var row: [ActKind] = []         // additional activities inside the extended notch
    }

    func makePlan() -> Plan {
        let a = acts
        if shape == .expanded {
            // an expanded card keeps the other activities as small icons beside the notch
            // only the tall cards have room beside the notch; one-line banners (charging, AirPods...) fill the whole band
            guard !hudActive, banner == nil, alertText == nil, let ck = cardKind, body == .media || body == .timer || body == .file || body == .info else { return Plan() }
            let others = a.filter { $0 != ck }
            switch others.count {
            case 0:  return Plan()
            case 1:  return Plan(left: others[0], right: others[0], rightDetail: true)
            default: return Plan(left: others[0], right: others[1])
            }
        }
        switch a.count {
        case 0:  return Plan()
        case 1:  return Plan(left: a[0], right: a[0], rightDetail: true)
        default: return Plan(left: a[0], right: a[1], row: Array(a.dropFirst(2)))
        }
    }

    // MARK: geometry (screen coordinates, y up)

    var notchLeft: CGFloat { screen.frame.midX - notchW / 2 }
    var notchRight: CGFloat { screen.frame.midX + notchW / 2 }
    /// Height of the compact island. Charging on its own stays within the menu bar (no taller than the notch).
    var compactH: CGFloat { (acts.count == 1 && acts[0] == .charging) ? notchH : notchH + 8 }

    func frame(for s: Shape) -> NSRect {
        let a = acts, n = a.count
        let mid = screen.frame.midX, top = screen.frame.maxY
        func r(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: top - h, width: w, height: h) }
        func compact(extra: CGFloat, h: CGFloat) -> NSRect {
            switch n {
            case 0: let w = notchW + extra; return r(mid - w / 2, w, h)
            case 1: let w = notchW + 2 * wingWidth(a[0]) + extra; return r(mid - w / 2, w, h)
            default:
                let wl = max(slotWing(a[0]), slotWing(a[1]))
                let w = max(notchW + 2 * wl, compactRowWidth + 36) + extra
                return r(mid - w / 2, w, h + compactRowHeight)
            }
        }
        switch s {
        case .collapsed: return r(notchLeft, notchW, notchH)
        case .activity:  return n == 0 ? r(notchLeft, notchW, notchH) : compact(extra: 0, h: compactH)
        case .peek:      return compact(extra: 24, h: n == 0 ? notchH : compactH)           // swells sideways only
        case .pressed:   return compact(extra: 44, h: n == 0 ? notchH + 6 : compactH)      // idle press: sideways AND a little down
        case .expanded:
            let (w, h) = expandedSize()
            let k = 1 + expandedSwell                                          // hover / press swell: the whole island scales
            return r(mid - w * k / 2, w * k, h * k)
        }
    }

    /// Resting size of the open island for the current body (no swell, no lyrics extension).
    func expandedSize() -> (w: CGFloat, h: CGFloat) {
        switch body {
        case .hud:    return (284, notchH + 40)                     // dropped below the notch
        case .banner:
            if case .airpods? = displayBanner { return (expandedCardWidth, notchH + 64) }
            return (notchW + 2 * bannerWing, notchH)
        default:      return (expandedCardWidth, notchH + expandedExtra)
        }
    }

    var compactRowHeight: CGFloat { acts.count >= 3 ? 42 : 0 }
    var compactRowWidth: CGFloat {
        let items = acts.dropFirst(2).compactMap { slotItem($0) }
        guard !items.isEmpty else { return 0 }
        return 28 + items.reduce(0) { $0 + $1.pillWidth } + 16 * CGFloat(max(items.count - 1, 0))
    }
}
