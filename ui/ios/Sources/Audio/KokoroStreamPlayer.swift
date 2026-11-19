import AVFoundation

/// Gapless streaming sink for the **free / Kokoro TTS lane**. Drives an
/// `AVAudioPlayerNode` — on its own per-utterance `AVAudioEngine`, or attached to the
/// barge-in spotter's voice-processing engine in dialog mode (see `sharedEngine`) — and
/// schedules each synthesized chunk (24 kHz mono float32) the moment it arrives, so
/// segment N plays while N+1 synthesizes. Built per utterance and torn down on drain /
/// barge-in (a fresh node per utterance also sidesteps stale audio graphs after a route
/// or configuration change).
///
/// Created/torn down on the main actor (`Speaker`), but `schedule(_:)` is called from the
/// synthesis thread — hence the lock and `@unchecked Sendable`. The `on*` callbacks fire
/// off the main actor; the owner hops them back.
final class KokoroStreamPlayer: @unchecked Sendable {
    private let engine: AVAudioEngine
    /// False when riding the barge-in spotter's voice-processing engine (see
    /// `KeywordSpotter.playbackEngine`) — then teardown only detaches our node and
    /// must never stop the engine, which keeps the mic open past playback.
    private let ownsEngine: Bool
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var outstanding = 0          // scheduled buffers not yet played out
    private var started = false
    private var draining = false         // synthesis done; waiting for buffers to drain
    private var stopped = false

    /// Fired once, when the very first buffer is scheduled (→ isSpeaking, drop the spinner).
    var onFirstBuffer: (() -> Void)?
    /// Per-chunk amplitude 0…1 (RMS) for the orb waveform.
    var onLevel: ((Double) -> Void)?
    /// Synthesis finished AND every scheduled buffer has drained (→ isSpeaking false).
    var onDrained: (() -> Void)?
    /// Mid-stream starvation: every scheduled buffer played out while synthesis is
    /// still producing the next chunk. Fired with `true` when playback runs dry and
    /// `false` when the next chunk lands — the owner shows a buffering spinner between
    /// the two.
    var onStall: ((Bool) -> Void)?
    private var stalled = false

    init(sampleRate: Double, sharedEngine: AVAudioEngine? = nil) {
        engine = sharedEngine ?? AVAudioEngine()
        ownsEngine = sharedEngine == nil
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)
            ?? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(node)
        // Connect at the model's rate; the mixer resamples to the output device rate, so
        // Kokoro's float samples feed through without us resampling.
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Schedule one synthesized chunk. Thread-safe; called from the synthesis thread.
    /// Lazily starts the engine on the first chunk.
    func schedule(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let dst = buf.floatChannelData?[0], let base = src.baseAddress else { return }
            dst.update(from: base, count: samples.count)
        }

        // RMS → 0…1 for the orb (the owner's decay timer eases it down between chunks).
        var sum: Float = 0
        for s in samples { sum += s * s }
        let level = Double(min(1, (sqrt(sum / Float(samples.count)) * 3.5)))

        lock.lock()
        if stopped { lock.unlock(); return }
        let resumed = stalled
        stalled = false
        let isFirst = !started
        if !started {
            // A shared (spotter) engine is usually already running; ours never is.
            if !engine.isRunning {
                engine.prepare()
                do { try engine.start() } catch { stopped = true; lock.unlock(); return }
            }
            node.play()
            started = true
        }
        outstanding += 1
        lock.unlock()

        if isFirst { onFirstBuffer?() }
        if resumed { onStall?(false) }
        onLevel?(level)

        node.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.outstanding -= 1
            let done = self.draining && self.outstanding == 0 && !self.stopped
            let dry = !self.draining && self.outstanding == 0 && !self.stopped
            if dry { self.stalled = true }
            self.lock.unlock()
            if done { self.onDrained?() }
            if dry { self.onStall?(true) }
        }
    }

    /// Mark synthesis complete; fires `onDrained` once the queued buffers play out (or now
    /// if none are pending).
    func synthesisFinished() {
        lock.lock()
        draining = true
        let done = started && outstanding == 0 && !stopped
        lock.unlock()
        if done { onDrained?() }
    }

    /// Barge-in / teardown: stop immediately and discard scheduled buffers. Idempotent.
    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        node.stop()
        if ownsEngine {
            engine.stop()
        } else {
            // Leave the spotter's engine running (it's still listening); just take
            // our node out of its graph so per-utterance nodes don't accumulate.
            engine.detach(node)
        }
    }
}
