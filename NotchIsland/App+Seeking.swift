import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Progress bar drag / sideways scroll seeking on the music card.

extension App {
    // MARK: seeking (progress bar drag, or sideways scrolling on the music card)

    func cancelPendingSeek() {
        seekTimer?.invalidate(); seekTimer = nil
        seekFraction = nil; seekTrack = nil
        seekHoldUntil = .distantPast
    }

    func scrubBy(_ d: CGFloat, _ m: Media) {
        guard m.duration > 0, m.trackID == media?.trackID else { return }
        seekTrack = m.trackID
        let base = seekFraction ?? CGFloat(m.elapsedNow / m.duration)
        seekFraction = min(1, max(0, base + d))
        refreshUI()
        seekTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in self?.commitSeek() }
        RunLoop.main.add(t, forMode: .common); seekTimer = t
    }

    func scrubbed(_ f: CGFloat, final: Bool) {
        if !final && scrubbingTrack == nil { scrubbingTrack = media?.trackID }
        let target = scrubbingTrack ?? media?.trackID
        if final { scrubbingTrack = nil }
        guard let target, target == media?.trackID else { cancelPendingSeek(); return }
        seekTimer?.invalidate(); seekTimer = nil
        seekTrack = target
        seekFraction = f
        if final { commitSeek() } else { refreshUI() }
    }

    func commitSeek() {
        guard let f = seekFraction, let target = seekTrack, var m = media,
              target == m.trackID, m.duration > 0 else { cancelPendingSeek(); return }
        cancelPendingSeek()
        let pos = Double(f) * m.duration
        sendMediaSeek(pos)
        m.elapsed = pos; m.readAt = Date(); media = m
        seekHoldUntil = Date().addingTimeInterval(1.5)
        refreshUI()
    }
}
