import AVFoundation

/// Original procedurally-synthesized electro-funk loop for NEON STRIKE — 808-style
/// kick/snare/hats, a square-wave synth bassline, and a saw arpeggio (≈112 BPM, A-minor
/// pentatonic). One looping track for now; mute persists across launches. Runs on its own
/// AVAudioEngine on the `.playback` category (mixing) so it plays regardless of the silent
/// switch and never fights the Bridge voice engine.
final class GameMusic {
    static let shared = GameMusic()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var prepared = false
    private(set) var muted: Bool

    // Per-level music: a small bank of styles (BPM + key transpose + rhythm/riff variant)
    // cycled by level. Rendered lazily and cached so a revisited style is instant.
    private var loops: [Int: AVAudioPCMBuffer] = [:]
    private var activeStyle = 0
    private var currentLevel = 1
    private var bossLoopBuf: AVAudioPCMBuffer?   // tense minor-key boss theme

    // SFX: a small pool of voices + pre-rendered buffers (shoot / hit / hurt / boom).
    private var sfxPlayers: [AVAudioPlayerNode] = []
    private var sfxIndex = 0
    private var lastHitT = 0.0   // throttle hit pings so stacked weapons don't drone

    // Looping thruster whine — a high machine tone whose volume tracks forward thrust.
    private let thrusterPlayer = AVAudioPlayerNode()
    private var thrusterBuf: AVAudioPCMBuffer?
    private var thrustVol: Float = 0

    // Boss-clear fanfare — its own voice so rapid auto-fire SFX can't interrupt it.
    private let fanfarePlayer = AVAudioPlayerNode()
    private var fanfareBuf: AVAudioPCMBuffer?
    private var shootBuf, shoot2Buf, shoot3Buf, shoot4Buf, hitBuf, hurtBuf, boomBuf, bossHitBuf, thonkBuf: AVAudioPCMBuffer?

    private init() { muted = UserDefaults.standard.bool(forKey: "inbox2_spaceshooter_muted") }

    func start() {
        prepare()
        engine.mainMixerNode.outputVolume = muted ? 0 : 0.7
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying, let b = buffer {
            player.scheduleBuffer(b, at: nil, options: .loops, completionHandler: nil)
            player.play()
        }
        if !thrusterPlayer.isPlaying, let tb = thrusterBuf {
            thrustVol = 0; thrusterPlayer.volume = 0
            thrusterPlayer.scheduleBuffer(tb, at: nil, options: .loops, completionHandler: nil)
            thrusterPlayer.play()
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func toggleMute() { setMuted(!muted) }

    func setMuted(_ m: Bool) {
        muted = m
        UserDefaults.standard.set(m, forKey: "inbox2_spaceshooter_muted")
        engine.mainMixerNode.outputVolume = m ? 0 : 0.7
        if m { thrustVol = 0; thrusterPlayer.volume = 0 }
    }

    /// Drive the thruster whine from forward thrust (0…1). Eased so it swells/fades
    /// smoothly; silent when muted or idle.
    func setThrust(_ level: Float) {
        guard prepared else { return }
        let target = muted ? 0 : min(1, max(0, level)) * 0.32   // engine whoosh under the mix
        thrustVol += (target - thrustVol) * 0.2
        thrusterPlayer.volume = thrustVol
    }

    /// Switch the backing loop to the style for `level` (cycles through the style bank).
    /// A no-op if the style is unchanged. Renders + caches the loop lazily.
    func setLevel(_ level: Int) {
        currentLevel = level
        let count = MusicStyle.all.count
        let id = (((max(1, level) - 1) % count) + count) % count
        guard id != activeStyle else { return }
        activeStyle = id
        play(loop(id))
    }

    /// Swap to the tense minor-key boss theme while a boss is on screen; restore the
    /// current level's track when it's over.
    func setBossMode(_ on: Bool) {
        play(on ? bossLoop() : loop(activeStyle))
    }

    /// Set `buffer` and, if we're already playing, hot-swap the loop.
    private func play(_ buf: AVAudioPCMBuffer) {
        buffer = buf
        guard prepared, engine.isRunning, player.isPlaying else { return }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }

    /// Lazily render + cache the loop for a style id.
    private func loop(_ id: Int) -> AVAudioPCMBuffer {
        if let cached = loops[id] { return cached }
        let b = makeLoop(sampleRate: 44_100, style: MusicStyle.all[id])
        loops[id] = b
        return b
    }

    /// Lazily render + cache the boss theme.
    private func bossLoop() -> AVAudioPCMBuffer {
        if let b = bossLoopBuf { return b }
        let b = makeLoop(sampleRate: 44_100, style: MusicStyle.boss)
        bossLoopBuf = b
        return b
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let buf = loop(activeStyle)
        buffer = buf
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buf.format)

        // SFX voices + buffers.
        for _ in 0..<6 {
            let p = AVAudioPlayerNode(); engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: buf.format)
            sfxPlayers.append(p)
        }

        // Thruster — a spinning-engine whoosh, not a tone: a band of inharmonic partials
        // (96–1200 Hz, pink rolloff so the low whoosh dominates) under a 24 Hz blade-pass
        // throb. 0.25s loop with every component at an integer cycle count → seamless.
        // tanh adds a little turbine grit and bounds the level.
        var tparts: [(Double, Double, Double)] = []   // (freq, amp, phase)
        var tseed: UInt32 = 9176
        func trnd() -> Double { tseed = tseed &* 1_664_525 &+ 1_013_904_223; return Double(tseed >> 8) / Double(1 << 24) }
        let tBase = 1.0 / 0.25   // 4 Hz fundamental → all harmonics are integer cycles/loop
        for k in 24...300 {
            let f = Double(k) * tBase
            let amp = (0.5 + trnd()) / pow(f / 120.0, 1.15)
            tparts.append((f, amp, trnd() * 2 * .pi))
        }
        thrusterBuf = sfx(0.25) { t in
            let spin = 0.55 + 0.45 * sin(2 * .pi * 24 * t)   // 6 cycles/loop blade-pass throb
            var v = 0.0
            for (f, a, ph) in tparts { v += a * sin(2 * .pi * f * t + ph) }
            return Float(tanh(v * spin * 0.08)) * 0.6
        }
        if let tb = thrusterBuf {
            engine.attach(thrusterPlayer)
            engine.connect(thrusterPlayer, to: engine.mainMixerNode, format: tb.format)
            thrusterPlayer.volume = 0
        }

        // Boss-clear fanfare — a quick staccato ascending arpeggio (C-E-G-C) into a
        // triumphant held major triad.
        fanfareBuf = sfx(1.2) { t in
            func sq(_ f: Double, _ lt: Double) -> Double { let p = f * lt; return (p - floor(p) < 0.5 ? 1 : -1) }
            var v = 0.0
            for (st, f) in [(0.00, 523.25), (0.09, 659.25), (0.18, 783.99), (0.27, 1046.5)]
                where t >= st && t < st + 0.16 {
                let lt = t - st
                v += sq(f, lt) * exp(-lt * 9) * 0.22
            }
            if t >= 0.36 {
                let lt = t - 0.36
                let env = min(1, lt * 18) * exp(-lt * 1.4)
                v += (sin(2 * .pi * 523.25 * lt) + sin(2 * .pi * 659.25 * lt)
                    + sin(2 * .pi * 783.99 * lt) + 0.5 * sin(2 * .pi * 1046.5 * lt)) * 0.12 * env
            }
            return Float(tanh(v * 1.3)) * 0.7
        }
        if let fb = fanfareBuf {
            engine.attach(fanfarePlayer)
            engine.connect(fanfarePlayer, to: engine.mainMixerNode, format: fb.format)
            fanfarePlayer.volume = 0.9
        }

        var seed: UInt32 = 22_222
        func nz() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 9) / Float(1 << 23) - 0.5 }
        // PULSE — bass-y thump-zap: low descending tone + a sub an octave down.
        shootBuf = sfx(0.16) { t in
            let f = 90.0 + 260.0 * exp(-t * 12)
            return (Float(sin(2 * .pi * f * t)) + 0.5 * Float(sin(2 * .pi * f * 0.5 * t))) * Float(exp(-t * 17)) * 0.42
        }
        // HYPER LASER — lower square zap with a sub layer.
        shoot2Buf = sfx(0.09) { t in
            let p = (380 + 520 * exp(-t * 18)) * t
            let sq: Float = (p - floor(p) < 0.5 ? 1 : -1)
            return (sq + 0.6 * Float(sin(2 * .pi * (110 + 90 * exp(-t * 10)) * t))) * Float(exp(-t * 24)) * 0.32
        }
        // SEEKER ROCKETS — low launch whoosh + noise.
        shoot3Buf = sfx(0.22) { t in (Float(sin(2 * .pi * (70 + 50 * exp(-t * 4)) * t)) * 0.6 + nz() * 0.45) * Float(exp(-t * 8)) * 0.5 }
        // HYPER KILLER BEAM — deep buzzy descending saw + sub.
        shoot4Buf = sfx(0.12) { t in
            let p = (240 + 320 * exp(-t * 14)) * t
            return (Float((p - floor(p)) * 2 - 1) + 0.5 * Float(sin(2 * .pi * 80 * t))) * Float(exp(-t * 18)) * 0.4
        }
        // Ship hit — laser-y descending zap (the old PULSE character).
        hitBuf   = sfx(0.1) { t in Float(sin(2 * .pi * (520 + 1400 * exp(-t * 16)) * t)) * Float(exp(-t * 28)) * 0.34 }
        hurtBuf  = sfx(0.35) { t in (Float(sin(2 * .pi * (50 + 200 * exp(-t * 3)) * t)) * 0.6 + nz() * 0.3) * Float(exp(-t * 7)) * 0.5 }
        boomBuf  = sfx(0.40) { t in nz() * Float(exp(-t * 9)) * 0.6 }
        // Boss hit — boomy low thud: deep sine + a little noise body.
        bossHitBuf = sfx(0.3) { t in
            let f = 58.0 + 80.0 * exp(-t * 8)
            return (Float(sin(2 * .pi * f * t)) * 0.75 + nz() * 0.35) * Float(exp(-t * 8)) * 0.6
        }
        // Weak-point hit — a woody "thonk": quick downward knock + click transient.
        thonkBuf = sfx(0.2) { t in
            let f = 150.0 + 130.0 * exp(-t * 38)
            let body = sin(2 * .pi * f * t)
            let click = Double(nz()) * exp(-t * 110)
            return Float((body + click * 0.6) * exp(-t * 15)) * 0.62
        }
    }

    /// Render a short mono SFX buffer from a per-sample function.
    private func sfx(_ dur: Double, sr: Double = 44_100, _ f: (Double) -> Float) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let n = Int(dur * sr)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        let out = b.floatChannelData![0]
        for i in 0..<n { out[i] = f(Double(i) / sr) }
        return b
    }

    func sfxShoot(_ tier: Int = 1) {
        switch tier {
        case 2:  playSFX(shoot2Buf)
        case 3:  playSFX(shoot3Buf)
        case 4:  playSFX(shoot4Buf)
        default: playSFX(shootBuf)
        }
    }
    func sfxHit()     { throttledHit(hitBuf) }
    func sfxBossHit() { throttledHit(bossHitBuf) }
    func sfxThonk()   { throttledHit(thonkBuf) }   // weak-point (2×) hit
    func sfxHurt()    { playSFX(hurtBuf) }
    func sfxBoom()    { playSFX(boomBuf) }

    /// Triumphant boss-clear fanfare (plays on its own dedicated voice).
    func sfxFanfare() {
        guard !muted, prepared, engine.isRunning, let b = fanfareBuf else { return }
        fanfarePlayer.stop()
        fanfarePlayer.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
        fanfarePlayer.play()
    }

    /// Coalesce rapid hit pings (many beams/seekers landing on the boss in one frame would
    /// otherwise overlap into a continuous tone) to at most ~22/sec.
    private func throttledHit(_ b: AVAudioPCMBuffer?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHitT >= 0.045 else { return }
        lastHitT = now
        playSFX(b)
    }

    private func playSFX(_ b: AVAudioPCMBuffer?) {
        guard !muted, let b, engine.isRunning, !sfxPlayers.isEmpty else { return }
        let p = sfxPlayers[sfxIndex]; sfxIndex = (sfxIndex + 1) % sfxPlayers.count
        p.stop()
        p.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
        p.play()
    }

    // MARK: synthesis

    /// One per-level music style: tempo, key transpose (semitones) and a rhythm/riff
    /// variant. All share the same A-minor-pentatonic synthesis so they stay cohesive.
    struct MusicStyle {
        let bpm: Double
        let semis: Double   // transpose all pitched parts (key change per level)
        let variant: Int    // selects bass riff + arp + drum pattern (see makeLoop)
        static let all: [MusicStyle] = [
            MusicStyle(bpm: 112, semis:  0, variant: 0),   // L1 — original electro-funk groove
            MusicStyle(bpm: 126, semis: -3, variant: 1),   // L2 — darker, four-on-the-floor
            MusicStyle(bpm: 132, semis:  4, variant: 2),   // L3 — brighter, syncopated
            MusicStyle(bpm: 100, semis: -5, variant: 3),   // L4 — slow & heavy
            MusicStyle(bpm: 140, semis:  7, variant: 4),   // L5 — frantic, dense hats
        ]
        /// Played while a boss is on screen — slow, low, brooding minor (variant 5).
        static let boss = MusicStyle(bpm: 100, semis: -1, variant: 5)
    }

    private func makeLoop(sampleRate sr: Double, style: MusicStyle) -> AVAudioPCMBuffer {
        let bpm = style.bpm
        let beat = sr * 60.0 / bpm
        let step = beat / 4.0            // 16th note
        let bars = 4
        let loopLen = Int(step * Double(16 * bars))
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(loopLen + Int(sr)))!
        pcm.frameLength = AVAudioFrameCount(loopLen)
        let out = pcm.floatChannelData![0]
        let n = Int(pcm.frameLength)
        for i in 0..<n { out[i] = 0 }
        func mix(_ s: Int, _ v: Float) { if s >= 0 && s < n { out[s] += v } }

        func kick(_ st: Int) {
            let start = Int(Double(st) * step), dur = Int(sr * 0.28)
            for k in 0..<dur {
                let t = Double(k) / sr
                let f = 48.0 + 80.0 * exp(-t * 30)
                mix(start + k, Float(sin(2 * Double.pi * f * t) * exp(-t * 14) * 0.9))
            }
        }
        func snare(_ st: Int) {
            let start = Int(Double(st) * step), dur = Int(sr * 0.18)
            var seed: UInt32 = 0x2545
            for k in 0..<dur {
                let t = Double(k) / sr, env = exp(-t * 22)
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Float(seed >> 9) / Float(1 << 23) - 0.5
                mix(start + k, (noise * 1.2 + Float(sin(2 * Double.pi * 190 * t)) * 0.4) * Float(env) * 0.5)
            }
        }
        func hat(_ st: Int, _ g: Float) {
            let start = Int(Double(st) * step), dur = Int(sr * 0.04)
            var seed: UInt32 = UInt32(truncatingIfNeeded: st * 7 + 3)
            for k in 0..<dur {
                let t = Double(k) / sr
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Float(seed >> 9) / Float(1 << 23) - 0.5
                mix(start + k, noise * 2 * Float(exp(-t * 60)) * g)
            }
        }
        func note(_ freq: Double, _ st: Int, _ lenSteps: Double, _ g: Float, square: Bool) {
            let start = Int(Double(st) * step), dur = Int(step * lenSteps)
            for k in 0..<dur {
                let t = Double(k) / sr
                let env = Float(min(1.0, t * 80) * exp(-t * 4.5))
                let ph = freq * t, frac = ph - floor(ph)
                let w: Float = square ? (frac < 0.5 ? 1 : -1) : Float(frac * 2 - 1)
                mix(start + k, w * env * g)
            }
        }

        // A-minor pentatonic, transposed per style for a per-level key change.
        let tf = pow(2.0, style.semis / 12.0)
        let A = 55.0 * tf, C = 65.41 * tf, D = 73.42 * tf, E = 82.41 * tf, G = 98.0 * tf, F = 87.31 * tf

        // Per-variant rhythm/riff selection.
        let bassRiff: [(Int, Double)]
        let arp: [Double]
        let arpSquare: Bool
        let arpEveryOtherBar: Bool
        let kicks: [Int]
        let oddBarKick: Int?
        let snares: [Int]
        let hatStride: Int
        switch style.variant {
        case 1:   // darker, four-on-the-floor
            bassRiff = [(0, A), (2, A), (4, E), (6, E), (8, G), (10, G), (12, D), (14, C)]
            arp = [A * 2, C * 2, E * 2, G * 2, E * 2, C * 2, A * 2, C * 2]
            arpSquare = true; arpEveryOtherBar = false
            kicks = [0, 4, 8, 12]; oddBarKick = nil; snares = [4, 12]; hatStride = 2
        case 2:   // brighter, syncopated
            bassRiff = [(0, A), (3, C), (6, D), (7, D), (10, E), (13, G)]
            arp = [A * 2, E * 2, A * 2, C * 4, D * 2, C * 4, A * 2, G * 2]
            arpSquare = false; arpEveryOtherBar = false
            kicks = [0, 6, 10, 12]; oddBarKick = 14; snares = [4, 12]; hatStride = 2
        case 3:   // slow & heavy
            bassRiff = [(0, A), (4, A), (8, F), (12, G)]
            arp = [A * 2, C * 4, A * 2, G * 2]
            arpSquare = true; arpEveryOtherBar = true
            kicks = [0, 3, 8, 11]; oddBarKick = nil; snares = [4, 12]; hatStride = 4
        case 4:   // frantic, dense
            bassRiff = [(0, A), (2, C), (4, E), (6, G), (8, A), (10, G), (12, E), (14, C)]
            arp = [A * 2, C * 4, E * 2, G * 2, A * 2, G * 2, E * 2, C * 4]
            arpSquare = false; arpEveryOtherBar = false
            kicks = [0, 3, 6, 8, 11, 14]; oddBarKick = nil; snares = [4, 12]; hatStride = 1
        case 5:   // BOSS — brooding minor: low drone bass + the minor-6th (F) for tension
            bassRiff = [(0, A), (4, F), (8, A), (10, G), (12, F)]
            arp = [A * 2, C * 2, E * 2, F * 2, E * 2, C * 2, A * 2, G * 2]
            arpSquare = true; arpEveryOtherBar = false
            kicks = [0, 6, 8, 14]; oddBarKick = nil; snares = [4, 12]; hatStride = 2
        default:  // 0 — original groove
            bassRiff = [(0, A), (3, A), (6, C), (8, E), (10, D), (11, C), (14, G)]
            arp = [E * 2, G * 2, A * 2, C * 4, A * 2, G * 2, E * 2, D * 2]
            arpSquare = false; arpEveryOtherBar = true
            kicks = [0, 6, 10]; oddBarKick = 14; snares = [4, 12]; hatStride = 2
        }

        for bar in 0..<bars {
            let base = bar * 16
            for k in kicks { kick(base + k) }
            if bar % 2 == 1, let ok = oddBarKick { kick(base + ok) }
            for s in snares { snare(base + s) }
            for s in stride(from: 0, to: 16, by: hatStride) { hat(base + s, s % 4 == 0 ? 0.22 : 0.15) }
            for (s, f) in bassRiff { note(f, base + s, 1.6, 0.22, square: true) }
            if !arpEveryOtherBar || bar % 2 == 0 {
                for (i, f) in arp.enumerated() { note(f, base + i * 2, 1.2, 0.10, square: arpSquare) }
            }
        }
        for i in 0..<n { out[i] = tanhf(out[i] * 1.2) * 0.9 }   // soft clip
        return pcm
    }
}
