import AppKit
import Accelerate
import AudioToolbox
import CoreAudio
import IOKit.ps

/// Real-time spectrum of whatever the Mac is playing: a global Core Audio process tap (macOS 14.2+; needs the
/// "system audio recording" permission, NOT screen recording) feeds a 1024-point FFT, folded into four bands.
final class AudioLevels {
    static let shared = AudioLevels()
    /// Written on the audio queue, read 30 times a second on the main thread: guarded, because an unsynchronised Swift array
    /// that is replaced while another thread reads it can hand out a torn buffer (that was the crash after hours of uptime).
    private let bandLock = NSLock()
    private var _bands = [Float](repeating: 0, count: 5)
    var bands: [Float] {
        get { bandLock.lock(); defer { bandLock.unlock() }; return _bands }
        set { bandLock.lock(); _bands = newValue; bandLock.unlock() }
    }
    private(set) var failed = false               // the tap could not be set up at all (permission missing / unsupported)
    private var watchdog: DispatchSourceTimer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private(set) var live = false                 // true once audio blocks actually arrive
    private var lastBlock = CFAbsoluteTimeGetCurrent() - 100
    private var tap = AudioObjectID(kAudioObjectUnknown), agg = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let n = 1024
    private var ring = [Float](repeating: 0, count: 1024), fill = 0, ringPos = 0     // ring: circular, oldest sample at ringPos
    private var ordered = [Float](repeating: 0, count: 1024)                      // scratch: the ring in time order
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)
    private var lastAnalysis = 0.0
    private var peaks = [Float](repeating: 0.0001, count: 5)
    private lazy var fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
    private let q = DispatchQueue(label: "ni.audio", qos: .userInteractive)
    private var nap: NSObjectProtocol?                  // keeps macOS from throttling the app (App Nap) while the island is collapsed
    private var users = 0
    private let debugAudio = ProcessInfo.processInfo.environment["NI_DEBUG"] != nil
    private var lastPrint = 0.0

    var fresh: Bool { CFAbsoluteTimeGetCurrent() - lastBlock < 1.0 }

    func retain() { q.async { self.users += 1; if self.users == 1 { self.begin() } } }
    func release() { q.async { self.users -= 1; if self.users == 0 { self.end() } } }

    /// The tap is tied to the output device it was built on: when the output changes (AirPods connect, a Bluetooth profile switch,
    /// the sample rate changes...) it goes silent. So rebuild it on every change, and whenever blocks stop arriving.
    private func begin() {
        start()
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restart() }
        outputListener = l
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, q, l)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: 1.0, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let s = self, s.users > 0, !s.failed, CFAbsoluteTimeGetCurrent() - s.lastBlock > 2.0, CFAbsoluteTimeGetCurrent() - s.startedAt > 2.0 else { return }
            s.restart()
        }
        t.resume(); watchdog = t
    }
    private func end() {
        watchdog?.cancel(); watchdog = nil
        if let l = outputListener {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, q, l); outputListener = nil
        }
        stop()
    }
    func debugStall() { q.async { if let p = self.proc { AudioDeviceStop(self.agg, p) } } }     // test hook: the tap silently dies
    private func restart() { guard users > 0 else { return }; stop(); start() }
    private var startedAt = CFAbsoluteTimeGetCurrent()

    private func start() {
        nap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "audio equalizer")
        guard #available(macOS 14.2, *), ProcessInfo.processInfo.environment["NI_NOAUDIO"] == nil else { return }
        startedAt = CFAbsoluteTimeGetCurrent(); lastBlock = startedAt
        failed = false
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID(); desc.muteBehavior = .unmuted; desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { failed = true; return }
        var outUID: String?
        var dev = AudioObjectID(kAudioObjectUnknown), sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr {
            var uid: Unmanaged<CFString>?; var s2 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var b = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(dev, &b, 0, nil, &s2, &uid) == noErr { outUID = uid?.takeRetainedValue() as String? }
        }
        var d: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchIsland tap",
            kAudioAggregateDeviceUIDKey: "com.kusbeoms.notchisland.tap.\(desc.uuid.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
        if let u = outUID { d[kAudioAggregateDeviceMainSubDeviceKey] = u; d[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: u]] }
        guard AudioHardwareCreateAggregateDevice(d as CFDictionary, &agg) == noErr else { stop(); failed = true; return }
        let st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, q) { [weak self] _, inData, _, _, _ in
            self?.consume(inData)
        }
        guard st == noErr, let p = proc, AudioDeviceStart(agg, p) == noErr else { stop(); failed = true; return }
    }

    private func stop() {
        if let n = nap { ProcessInfo.processInfo.endActivity(n); nap = nil }
        if let p = proc { AudioDeviceStop(agg, p); AudioDeviceDestroyIOProcID(agg, p); proc = nil }
        if agg != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(agg); agg = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
        bands = [0, 0, 0, 0, 0]; live = false; fill = 0; ringPos = 0
    }

    private func consume(_ list: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let b = abl.first, let raw = b.mData else { return }
        let ch = max(1, Int(b.mNumberChannels)), frames = Int(b.mDataByteSize) / (4 * ch)
        let x = raw.assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            var v: Float = 0
            for c in 0..<ch { v += x[i * ch + c] }
            ring[ringPos] = v / Float(ch); ringPos = (ringPos + 1) % n
        }
        fill = min(n, fill + frames)
        let now = CFAbsoluteTimeGetCurrent()
        lastBlock = now; live = true
        guard now - lastAnalysis >= 1.0 / 40 else { return }       // the bars only redraw at 30Hz: no need for a FFT per audio block
        lastAnalysis = now
        analyse()
    }

    private func analyse() {
        guard let fft else { return }
        var win = [Float](repeating: 0, count: n)
        ordered.replaceSubrange(0..<(n - ringPos), with: ring[ringPos...])
        ordered.replaceSubrange((n - ringPos)..<n, with: ring[..<ringPos])
        vDSP.multiply(ordered, window, result: &win)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var sp = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            win.withUnsafeBufferPointer { w in
                w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sp, 1, vDSP_Length(n / 2)) }
            }
            fft.forward(input: sp, output: &sp)
            vDSP.absolute(sp, result: &mags)
        } }
        let hz = Float(48000) / Float(n)                       // good enough: 44.1k/48k differ by under 9%
        let edges: [Float] = [40, 150, 500, 1600, 5000, 13000]
        var out = [Float](repeating: 0, count: 5)
        for k in 0..<5 {
            let lo = max(1, Int(edges[k] / hz)), hi = min(n / 2 - 1, Int(edges[k + 1] / hz))
            guard hi > lo else { continue }
            let e = vDSP.mean(Array(mags[lo...hi]))
            peaks[k] = max(e, peaks[k] * 0.995)                // slow auto-gain: lively at any volume
            out[k] = peaks[k] > 0.001 ? min(1, pow(e / peaks[k], 0.8)) : 0
        }
        bands = out
        if debugAudio, CFAbsoluteTimeGetCurrent() - lastPrint > 0.5 { lastPrint = CFAbsoluteTimeGetCurrent(); FileHandle.standardError.write("bands \(out)\n".data(using: .utf8)!) }
    }
}

/// Five bars that dance to the real audio (falls back to a canned loop when no audio can be tapped).
