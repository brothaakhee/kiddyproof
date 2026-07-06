import AVFoundation
import AppKit

// Procedural, permission-free audio tuned for CALM. One persistent AVAudioEngine built
// once at launch. Signal chain:
//
//   voice pool + vacuum hum ─► wet mixer ─► reverb ─► main mixer ─► output
//   ambient bed ───────────────────────────────────► main mixer (dry)
//
// • A soft, slowly-evolving ambient BED drones the whole time (sets a calm mood on its own).
// • A low VACUUM hum that SWELLS with a scene's audioSwell (the black hole's suction).
// • Reverb gives every accent a spacious tail so nothing sounds sharp.
// • One-shot accents are heavily throttled (handled here + by callers), and the black hole
//   uses a single soft "burst" whoomph on release instead of a per-keystroke barrage.
// All buffers are synthesized at boot (no asset files); loops are seamless (frequencies are
// integer multiples of 1/loopLength). Triggered only from the render tick, never the tap.
final class KidAudio {
    private(set) var enabled = false      // silent until kid mode arms (set via setEnabled)
    private var volume: Float = 0.8

    private let engine = AVAudioEngine()
    // Stereo canonical format — effect units (the reverb) universally accept stereo; the
    // mono synthesis is written to both channels.
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                    channels: 2, interleaved: false)!
    private let wetMixer = AVAudioMixerNode()
    private let reverb = AVAudioUnitReverb()
    // Peak limiter between the main mixer and the device: 16 voices + beds + booms can
    // sum past 0 dBFS under a sustained multi-channel mash, and digital clipping is
    // exactly the harsh sound this product must never make — into toddler ears.
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0))
    private let drone = AVAudioPlayerNode()      // ambient bed (constant, dry)
    private let vacuum = AVAudioPlayerNode()     // low hum, swelled by the scene
    private let voiceCount = 16
    private var voices: [AVAudioPlayerNode] = []
    private var lastUsed: [UInt64] = []
    private var globalTick: UInt64 = 0

    private var notes: [AVAudioPCMBuffer] = []
    private var drips: [AVAudioPCMBuffer] = []      // water droplets (Ripples' click voice)
    private var plucks: [AVAudioPCMBuffer] = []     // silk strings (Silk's pluck voice)
    private var bonkBuf, boomBuf, whooshBuf, burstBuf, glimmerBuf, pingBuf, droneBuf, vacuumBuf: AVAudioPCMBuffer?
    private var rng = RNG(seed: 0xA0D10)

    private var lastPlay: [Int: TimeInterval] = [:]
    private var configToken: NSObjectProtocol?
    private var booted = false
    private var primed = false        // players/beds started (first enable)
    private var needsReprime = false  // device config changed while paused
    private var vacLevel: Float = 0
    private let bedLevel: Float = 0.14

    // MARK: Boot

    // Builds the graph and synthesizes all buffers ONCE — but does NOT start the
    // engine. A running AVAudioEngine holds the output device and burns CPU 24/7;
    // the engine only runs while kid mode is armed (setEnabled), and arming stays
    // cheap because everything here is already prepared.
    func boot() {
        guard !booted else { return }
        booted = true
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 30
        engine.attach(wetMixer); engine.attach(reverb); engine.attach(drone)
        engine.attach(vacuum); engine.attach(limiter)
        engine.connect(wetMixer, to: reverb, format: fmt)
        engine.connect(reverb, to: engine.mainMixerNode, format: fmt)
        engine.connect(drone, to: engine.mainMixerNode, format: fmt)   // bed stays dry & clean
        engine.connect(vacuum, to: wetMixer, format: fmt)
        engine.connect(engine.mainMixerNode, to: limiter, format: fmt) // everything passes the
        engine.connect(limiter, to: engine.outputNode, format: fmt)    // limiter before the device
        for _ in 0..<voiceCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: wetMixer, format: fmt)
            voices.append(node); lastUsed.append(0)
        }
        synthesize()
        engine.mainMixerNode.outputVolume = 0   // volume set on enable
        configToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.reprime() }
        engine.prepare()
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { NSLog("[kiddyproof] audio engine failed to start: \(error) — silent.") }
    }

    private func startBeds() {
        guard engine.isRunning else { return }
        if let b = droneBuf { drone.scheduleBuffer(b, at: nil, options: .loops, completionHandler: nil) }
        if let b = vacuumBuf { vacuum.scheduleBuffer(b, at: nil, options: .loops, completionHandler: nil) }
        drone.volume = bedLevel
        vacuum.volume = 0
        drone.play(); vacuum.play()
    }

    private func reprime() {
        // Output device changed. If we're paused, just remember to rebuild playback on
        // the next enable — never wake the engine while kid mode is off.
        guard enabled else { needsReprime = true; return }
        for v in voices { v.stop() }
        drone.stop(); vacuum.stop()
        startEngine()
        for v in voices where engine.isRunning { v.play() }
        startBeds()
    }

    // MARK: Public surface (render tick only)

    func setEnabled(_ on: Bool) {
        enabled = on
        engine.mainMixerNode.outputVolume = on ? volume : 0   // mutes everything incl. beds
        if on {
            startEngine()
            if !primed || needsReprime {
                needsReprime = false
                for v in voices { v.stop() }
                drone.stop(); vacuum.stop()
                for v in voices where engine.isRunning { v.play() }
                startBeds()
                // Only latch primed on SUCCESS: latching on a transient engine-start
                // failure left every player node dead for all future sessions.
                primed = engine.isRunning
            }
        } else if engine.isRunning {
            engine.pause()   // release the CPU + output device between sessions
        }
    }
    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        if enabled { engine.mainMixerNode.outputVolume = volume }
    }

    // A scene's continuous "swell" 0…1 (the black hole's suction) drives the vacuum hum.
    func setSwell(_ level: CGFloat, dt: CGFloat) {
        guard enabled else { return }
        let target = Float(max(0, min(1, level)))
        vacLevel += (target - vacLevel) * Float(min(1, dt * 6))
        vacuum.volume = vacLevel * 0.55
    }

    func note(for key: String, intensity: CGFloat) {
        guard !notes.isEmpty, !throttled(0, 0.07) else { return }
        play(notes[Int(key.unicodeScalars.first?.value ?? 0) % notes.count], gain: 0.32 + 0.4 * Float(clamp01(intensity)))
    }
    func bonk(intensity: CGFloat) { if let b = bonkBuf, !throttled(1, 0.06) { play(b, gain: 0.4 + 0.4 * Float(clamp01(intensity))) } }
    func boom(intensity: CGFloat) { if let b = boomBuf, !throttled(2, 0.07) { play(b, gain: 0.5 + 0.45 * Float(clamp01(intensity))) } }
    func whoosh() { if let b = whooshBuf, !throttled(3, 0.09) { play(b, gain: 0.45) } }
    // Soft reverb-tailed "whoomph" — the black hole's release burst.
    func burst() { if let b = burstBuf, !throttled(4, 0.18) { play(b, gain: 0.6) } }   // sparse, soft whisper
    // A water droplet "bloop" — the Ripples scene's click/heartbeat voice. Random pitch
    // variant per call so a rhythm of drops never sounds like a sampler.
    func drip(intensity: CGFloat = 1) {
        guard !drips.isEmpty, !throttled(5, 0.06) else { return }
        play(drips[rng.int(drips.count)], gain: 0.3 + 0.35 * Float(clamp01(intensity)))
    }
    // A soft glass chime — Drift's light wave rolling through the fireflies.
    func glimmer() { if let b = glimmerBuf, !throttled(6, 0.12) { play(b, gain: 0.4) } }
    // A crystalline starlight ping — Constellation's pulse voice.
    func ping() { if let b = pingBuf, !throttled(7, 0.1) { play(b, gain: 0.34) } }
    // A plucked silk string — the Silk scene's voice. Random pitch per pluck.
    func pluck(intensity: CGFloat = 1) {
        guard !plucks.isEmpty, !throttled(8, 0.07) else { return }
        play(plucks[rng.int(plucks.count)], gain: 0.28 + 0.3 * Float(clamp01(intensity)))
    }

    // MARK: Internals

    private func clamp01(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    private func throttled(_ bucket: Int, _ gap: TimeInterval) -> Bool {
        let now = CACurrentMediaTime()
        if let t = lastPlay[bucket], now - t < gap { return true }
        lastPlay[bucket] = now; return false
    }
    private func play(_ buffer: AVAudioPCMBuffer, gain: Float) {
        guard enabled, engine.isRunning else { return }
        var idx = 0, oldest = lastUsed[0]
        for i in 1..<voices.count where lastUsed[i] < oldest { oldest = lastUsed[i]; idx = i }
        globalTick &+= 1; lastUsed[idx] = globalTick
        let v = voices[idx]
        v.volume = gain
        if v.isPlaying { v.stop() }
        v.play()   // always (re)start: scheduling onto a stopped node queues silence
        v.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    // MARK: Synthesis (boot-time only)

    private func synthesize() {
        let pent: [Double] = [261.63, 293.66, 329.63, 392.00, 440.00]
        notes = (pent + pent.map { $0 * 2 }).map { makeNote(freq: $0) }
        bonkBuf = makeBonk(); boomBuf = makeBoom(); whooshBuf = makeWhoosh()
        burstBuf = makeBurst(); glimmerBuf = makeGlimmer(); pingBuf = makePing()
        droneBuf = makeDrone(); vacuumBuf = makeVacuum()
        drips = [420.0, 540.0, 660.0, 800.0].map { makeDrip(freq: $0) }
        plucks = [329.63, 392.0, 440.0, 523.25].map { makePluck(freq: $0) }   // E4 G4 A4 C5
    }

    // loop=true → no head/tail fade (callers ensure seamless waveforms).
    private func makeBuffer(_ seconds: Double, loop: Bool = false, _ sample: (Int, Double) -> Float) -> AVAudioPCMBuffer? {
        let n = AVAudioFrameCount(seconds * fmt.sampleRate)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n), let cd = buf.floatChannelData else { return nil }
        buf.frameLength = n
        let ch0 = cd[0], ch1 = cd[1]
        let sr = fmt.sampleRate, total = Int(n), fade = max(1, Int(0.003 * sr))
        for i in 0..<total {
            var s = sample(i, Double(i) / sr)
            if !loop {
                if i < fade { s *= Float(i) / Float(fade) }
                let tail = total - i; if tail < fade { s *= Float(tail) / Float(fade) }
            }
            ch0[i] = s; ch1[i] = s
        }
        return buf
    }

    private func makeNote(freq: Double) -> AVAudioPCMBuffer {
        makeBuffer(0.7) { _, t in
            let env = Float(exp(-t * 4.0))      // softer/longer than before (reverb adds the tail)
            return 0.18 * env * Float(sin(2 * .pi * freq * t) + 0.25 * sin(2 * .pi * freq * 2 * t))
        }!
    }
    private func makeBonk() -> AVAudioPCMBuffer {
        makeBuffer(0.18) { _, t in 0.28 * Float(exp(-t * 22)) * Float(sin(2 * .pi * 200 * t) + 0.4 * sin(2 * .pi * 360 * t)) }!
    }
    private func makeBoom() -> AVAudioPCMBuffer {
        var r = RNG(seed: 0xB001)
        return makeBuffer(0.7) { _, t in
            let env = Float(exp(-t * 5.5)); let low = sin(2 * .pi * 70 * t) + 0.5 * sin(2 * .pi * 45 * t)
            return env * Float(0.4 * low + 0.16 * (Double(r.unit()) * 2 - 1) * exp(-t * 12))
        }!
    }
    private func makeWhoosh() -> AVAudioPCMBuffer {
        var r = RNG(seed: 0x5400); let dur = 0.35
        return makeBuffer(dur) { _, t in 0.16 * Float(sin(.pi * t / dur)) * Float(Double(r.unit()) * 2 - 1) }!
    }
    // Whispered release: a soft breathy (low-passed) exhale as the main character, a quiet
    // downward thread + a whisper of low-end for depth, snappy and gentle.
    private func makeBurst() -> AVAudioPCMBuffer {
        var r = RNG(seed: 0xB0F7)
        var lp: Double = 0
        let tau = 2.0 * Double.pi
        let T = 0.45, f0 = 200.0, f1 = 95.0
        return makeBuffer(T) { _, t in
            let attack: Double = t < 0.006 ? t / 0.006 : 1
            let env = attack * exp(-t * 6.5)                       // snappy/quick
            let n = Double(r.unit()) * 2 - 1
            lp += (n - lp) * 0.14                                  // 1-pole low-pass → breathy, not harsh
            var s = lp * 0.7                                       // the airy whisper
            let sweepPhase = tau * (f0 * t + (f1 - f0) / (2 * T) * t * t)
            s += sin(sweepPhase) * 0.32                            // subtle downward motion
            s += sin(tau * 52 * t) * 0.22                          // quiet low-end depth
            return Float(0.34 * env * s)
        }!
    }
    // A plucked string: harmonics decaying faster the higher they are (the signature
    // of real plucked strings — bright at the attack, mellowing as it rings), with a
    // tiny pick transient. Gentle, harp-like, nothing percussive.
    private func makePluck(freq f: Double) -> AVAudioPCMBuffer {
        var r = RNG(seed: UInt64(f) &* 7)
        let tau = 2.0 * Double.pi
        return makeBuffer(0.9) { _, t in
            let attack: Double = t < 0.002 ? t / 0.002 : 1
            var s: Double = 0
            for h in 1...5 {
                let hd = Double(h)
                let tone: Double = sin(tau * f * hd * t)
                let level: Double = 1.0 / pow(hd, 1.3)
                let decay: Double = exp(-t * (2.5 + hd * 2.2))
                s += tone * level * decay
            }
            let noise = Double(r.unit()) * 2 - 1
            s += noise * exp(-t * 220) * 0.15   // pick transient
            return Float(0.2 * attack * s)
        }!
    }

    // A starlight ping: one pure high tone with a whisper of detune shimmer — brief,
    // crystalline, immediately distinct from the glass glimmer's bell.
    private func makePing() -> AVAudioPCMBuffer {
        let tau = 2.0 * Double.pi
        let f = 1318.5   // E6
        return makeBuffer(0.55) { _, t in
            let attack: Double = t < 0.004 ? t / 0.004 : 1
            let env = attack * exp(-t * 7.5)
            var s = sin(tau * f * t) * 0.75
            s += sin(tau * (f * 1.006) * t) * 0.25       // detune shimmer
            s += sin(tau * f * 3 * t) * 0.06 * exp(-t * 16)
            return Float(0.14 * env * s)
        }!
    }

    // A water droplet: the physics of a real drop is a tiny impact tick followed by a
    // resonating bubble whose pitch RISES as it collapses — a sine chirp (f0 → ~2.2·f0)
    // with a fast decay nails the familiar "bloop". The reverb gives it the pond.
    private func makeDrip(freq f0: Double) -> AVAudioPCMBuffer {
        var r = RNG(seed: UInt64(f0))
        let tau = 2.0 * Double.pi
        return makeBuffer(0.32) { _, t in
            let attack: Double = t < 0.003 ? t / 0.003 : 1
            let env = attack * exp(-t * 14)
            // rising chirp: instantaneous freq f0·(1 + 2.4t) → phase integral below
            let phase = tau * f0 * (t + 1.2 * t * t)
            var s = sin(phase) * 0.8
            s += sin(phase * 2) * 0.12                        // faint brightness
            s += Double(r.unit() * 2 - 1) * exp(-t * 90) * 0.25   // the impact tick
            return Float(0.3 * env * s)
        }!
    }

    // A glass glimmer: two slightly inharmonic partials with a gentle attack and a long
    // reverb-carried tail — light rolling through the field, nothing percussive.
    private func makeGlimmer() -> AVAudioPCMBuffer {
        let tau = 2.0 * Double.pi
        let f = 880.0
        return makeBuffer(1.1) { _, t in
            let attack: Double = t < 0.025 ? t / 0.025 : 1
            let env = attack * exp(-t * 3.6)
            var s = sin(tau * f * t) * 0.6
            s += sin(tau * f * 2.76 * t) * 0.22 * exp(-t * 6)   // bell-like inharmonic sparkle
            s += sin(tau * f * 0.5 * t) * 0.2                   // warm under-octave
            return Float(0.16 * env * s)
        }!
    }

    // Seamless 8s ambient bed: low detuned sines + a slow 0.25Hz swell.
    private func makeDrone() -> AVAudioPCMBuffer {
        let tau = 2.0 * Double.pi
        return makeBuffer(8.0, loop: true) { _, t in
            let lfo: Double = 0.6 + 0.4 * sin(tau * 0.25 * t)
            var s: Double = sin(tau * 55 * t) * 0.5
            s += sin(tau * 55.25 * t) * 0.5
            s += sin(tau * 82.5 * t) * 0.3
            s += sin(tau * 110 * t) * 0.2
            s += sin(tau * 110.5 * t) * 0.2
            return Float(0.16 * lfo * s)
        }!
    }
    // Seamless 4s low hum with slight beating — swelled by setSwell during suction.
    private func makeVacuum() -> AVAudioPCMBuffer {
        let tau = 2.0 * Double.pi
        return makeBuffer(4.0, loop: true) { _, t in
            var s: Double = sin(tau * 73 * t) * 0.5
            s += sin(tau * 73.5 * t) * 0.5
            s += sin(tau * 110 * t) * 0.32
            s += sin(tau * 146.5 * t) * 0.24
            s += sin(tau * 220.25 * t) * 0.12
            return Float(0.22 * s)
        }!
    }

    deinit {
        if let token = configToken { NotificationCenter.default.removeObserver(token) }
        engine.stop()
    }
}
