import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Button and menu actions, dismissing the island, demos.

extension App {
    /// Demos: a stopwatch, or (NI_COUNTDOWN=1) a one-minute timer.
    func startDemoTimer() {
        if ProcessInfo.processInfo.environment["NI_COUNTDOWN"] != nil { timer.startCountdown(minutes: 1) } else { timer.toggle() }
    }

    /// The one place that closes the open island on the user's behalf (outside click, Esc, Cmd+., sensor, notch tap).
    /// A locked island refuses; new dismiss paths go through here instead of repeating the `locked` check.
    @discardableResult func dismissIsland(clearHUD: Bool = false, keepPinned: Bool = false) -> Bool {
        guard !locked else { return false }
        if clearHUD && hudActive { hudUntil = .distantPast }
        if !keepPinned { pinned = false; alertText = nil; banner = nil }
        return true
    }

    func wire(_ b: NSButton, _ sel: Selector) { b.target = self; b.action = sel }

    // MARK: actions

    @objc func prevTapped() { if demoMedia { return }; sendMediaCommand(5); pollSoon() }
    @objc func nextTapped() { if demoMedia { return }; sendMediaCommand(4); pollSoon() }
    @objc func playPauseTapped() {
        var wantPlay = true
        if var m = media {                           // flip the icon at once; the poll after the command confirms it
            m.elapsed = m.elapsedNow; m.readAt = Date(); m.playing.toggle()
            wantPlay = m.playing
            if m.playing { lastPlayingAt = Date() }
            media = m
        }
        if !demoMedia {
            playTapGeneration += 1
            let generation = playTapGeneration
            playHoldUntil = Date().addingTimeInterval(2.5)    // polls that still show the old state are ignored meanwhile
            sendMediaCommand(wantPlay ? 0 : 1) { [weak self] in    // explicit play / pause: a toggle can land the wrong way
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.confirmPlayState(wantPlay, retry: true, generation: generation) }
            }
        }
        refreshUI()
    }
    /// If the player ignored the command (no MediaRemote client), press the media key once, then take the real state.
    /// A newer tap supersedes this check, so a stale `wantPlay` can never press the key against the user's last intent.
    func confirmPlayState(_ wantPlay: Bool, retry: Bool, generation: Int) {
        guard generation == playTapGeneration else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = queryNowPlaying()
            DispatchQueue.main.async {
                guard let self, generation == self.playTapGeneration else { return }
                if retry, case .media(let m) = r, m.playing != wantPlay, m.trackID == self.media?.trackID {
                    postPlayPauseKey()
                    self.pollSoon()                      // the regular poll reports the outcome; the hold covers the gap
                    return
                }
                self.playHoldUntil = .distantPast
                self.applyPolled(r)
            }
        }
    }

    @objc func timerToggleTapped() { timer.toggle(); refreshUI() }
    @objc func timerCancelTapped() { timer.reset(); refreshUI() }
    func pollSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pollMusic() } }
}
