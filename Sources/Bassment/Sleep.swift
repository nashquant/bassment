import AVFoundation
import Foundation

enum SleepSound: String, CaseIterable, Identifiable {
    case pink, brown, rain, ocean, ambient432
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pink: "Pink noise"
        case .brown: "Brown noise"
        case .rain: "Rain"
        case .ocean: "Ocean"
        case .ambient432: "432 Hz ambient"
        }
    }
}

/// Procedural sleep sounds, all made from noise (no audio files).
/// Each channel has its own noise: uncorrelated left and right sound wide, around the listener.
struct NoiseGen {
    struct Channel {
        var seed: UInt32
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, brown: Float = 0
        var hp: Float = 0, lp: Float = 0, drop: Float = 0

        mutating func white() -> Float { // xorshift32, -1...1
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return Float(Int32(bitPattern: seed)) * (1 / 2147483648)
        }

        mutating func pink(_ w: Float) -> Float { // Paul Kellet's economy filter, -3 dB/octave
            b0 = 0.99765 * b0 + w * 0.0990460
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            return (b0 + b1 + b2 + w * 0.1848) * 0.25
        }

        mutating func nextBrown(_ w: Float) -> Float { // leaky integrator, -6 dB/octave
            brown = (brown + 0.02 * w) / 1.02
            return brown * 3.5
        }
    }

    var sound = SleepSound.brown
    var target: Float = 0.5                // written by the UI, followed smoothly
    private(set) var gain: Float = 0
    private var l = Channel(seed: 0x1234_5678), r = Channel(seed: 0x9E37_79B9)
    private var wave: Float = 0, period: Float = 9
    private var music: Ambient432
    private let fs: Float, smooth: Float, dropRate: Float, dropDecay: Float, rainLow: Float, rainHigh: Float

    init(sampleRate: Float) {
        fs = sampleRate
        music = Ambient432(sampleRate: sampleRate)
        smooth = 1 - expf(-1 / (0.05 * sampleRate))       // ~50 ms gain glide: no clicks
        dropRate = 40 / sampleRate                          // droplets per sample per channel
        dropDecay = expf(-1 / (0.004 * sampleRate))         // 4 ms droplet tail
        rainLow = 1 - expf(-2 * .pi * 400 / sampleRate)     // rain band: 400 Hz – 7 kHz
        rainHigh = 1 - expf(-2 * .pi * 7000 / sampleRate)
    }

    /// Wave swell 0.12...1: fast rise (30% of the cycle), long fall.
    private static func swell(_ phase: Float) -> Float {
        let p = phase - phase.rounded(.down)
        let x = p < 0.3 ? p / 0.3 : 1 - (p - 0.3) / 0.7
        return 0.12 + 0.88 * x * x * (3 - 2 * x)
    }

    private func sample(_ c: inout Channel, env: Float) -> Float {
        let w = c.white()
        switch sound {
        case .pink:
            return c.pink(w) * 0.25
        case .brown:
            return c.nextBrown(w) * 0.55
        case .rain:
            let p = c.pink(w)
            if (w + 1) * 0.5 < dropRate { c.drop = 0.3 + 0.7 * abs(c.white()) }
            c.drop *= dropDecay
            let x = p * 0.6 + c.white() * c.drop
            c.hp += rainLow * (x - c.hp)
            c.lp += rainHigh * ((x - c.hp) - c.lp)
            return c.lp * 0.7
        case .ocean:
            let x = c.nextBrown(w) * 0.6 + c.pink(w) * 0.4
            let a = 1 - expf(-2 * .pi * (250 + 2200 * env * env) / fs) // brighter at the crest
            c.lp += a * (x - c.lp)
            return c.lp * env * 0.7
        case .ambient432:
            return 0 // rendered in render(): one music source for both channels
        }
    }

    mutating func render(l outL: UnsafeMutablePointer<Float>, r outR: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            var eL: Float = 1, eR: Float = 1
            if sound == .ocean {
                wave += 1 / (period * fs)
                if wave >= 1 { wave -= 1; period = 7 + 5 * abs(l.white()) } // next wave in 7–12 s
                eL = Self.swell(wave)
                eR = Self.swell(wave + 0.06) // the wave reaches one ear a little later
            }
            gain += (target - gain) * smooth
            if sound == .ambient432 {
                let (a, b) = music.next()
                outL[i] = min(max(a * gain, -1), 1)
                outR[i] = min(max(b * gain, -1), 1)
                continue
            }
            outL[i] = min(max(sample(&l, env: eL) * gain, -1), 1)
            outR[i] = min(max(sample(&r, env: eR) * gain, -1), 1)
        }
    }
}

/// Generative ambient music tuned to A = 432 Hz: slow pad chords that cross-fade into each other,
/// plus a soft singing-bowl note now and then. The Ambience engine adds a large reverb.
struct Ambient432 {
    /// Sine oscillator by complex rotation: 4 multiplies per sample, no sinf.
    struct Osc {
        var re: Float = 1, im: Float = 0, cr: Float = 1, ci: Float = 0
        mutating func set(freq: Float, fs: Float, phase: Float) {
            re = cosf(phase); im = sinf(phase)
            cr = cosf(2 * .pi * freq / fs); ci = sinf(2 * .pi * freq / fs)
        }
        mutating func next() -> Float {
            let r = re * cr - im * ci
            im = re * ci + im * cr
            re = r
            return im
        }
        mutating func renorm() { let m = 1 / (re * re + im * im).squareRoot(); re *= m; im *= m }
    }

    /// One pad note: three slightly detuned fundamentals (slow beating = movement), octave and twelfth.
    struct Voice {
        var osc = [Osc](repeating: Osc(), count: 5)
        var panL: Float = 0.7, panR: Float = 0.7, lfo: Float = 0, lfoRate: Float = 0.05
    }

    static let partials: [(ratio: Float, amp: Float)] = [(1, 0.3), (1.0021, 0.3), (0.9979, 0.3), (2, 0.18), (3, 0.05)]
    /// Semitones from A4 = 432 Hz: Am9, Fmaj7, Cmaj7, Em7, voiced wide and low.
    static let chords: [[Float]] = [[-24, -17, -12, -9, -5, 2], [-28, -21, -16, -12, -9, -5],
                                    [-21, -14, -9, -5, -2, 2], [-29, -22, -17, -14, -7, -2]]
    static let bellNotes: [Float] = [-12, -9, -7, -5, 0, 3, 5, 7] // A minor pentatonic
    static let block = 32                                       // control rate: envelopes every 32 samples

    private let fs: Float
    private var seed: UInt32 = 0x2545_F491
    private var banks = [[Voice]](repeating: [Voice](repeating: Voice(), count: 6), count: 2)
    private var level: [Float] = [0, 0], target: [Float] = [1, 0]
    private var gains = [Float](repeating: 0, count: 24)        // per bank × voice × L/R, at control rate
    private var active = 0, chord = 0, clock = 0, phaseInBlock = 0
    private var bell = [Osc](repeating: Osc(), count: 3), bellEnv: [Float] = [0, 0, 0], bellDecay: [Float] = [0, 0, 0]
    private var bellAttack: Float = 0, bellPan: Float = 0.5, nextBell = 0
    private let chordLen: Int, fadeLen: Int

    init(sampleRate: Float) {
        fs = sampleRate
        chordLen = Int(26 * sampleRate)
        fadeLen = Int(9 * sampleRate)
        bellDecay = [5, 2.5, 1.2].map { expf(-1 / ($0 * sampleRate)) }
        nextBell = Int(6 * sampleRate)
        setChord(bank: 0, chord: 0)
    }

    private mutating func random() -> Float { // 0...1
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(seed) / Float(UInt32.max)
    }

    private static func freq(_ semis: Float) -> Float { 432 * powf(2, semis / 12) }

    private mutating func setChord(bank: Int, chord c: Int) {
        for (v, semis) in Self.chords[c].enumerated() {
            for (k, p) in Self.partials.enumerated() {
                banks[bank][v].osc[k].set(freq: Self.freq(semis) * p.ratio, fs: fs, phase: random() * 2 * .pi)
            }
            let pan = 0.15 + 0.7 * random()
            banks[bank][v].panL = cosf(pan * .pi / 2)
            banks[bank][v].panR = sinf(pan * .pi / 2)
            banks[bank][v].lfo = random()
            banks[bank][v].lfoRate = 0.03 + 0.06 * random()
        }
    }

    private mutating func control() {
        let dt = Float(Self.block) / fs
        clock += Self.block
        if target[active] == 1, clock >= chordLen - fadeLen { // start the cross-fade to a different chord
            var next = chord
            while next == chord { next = Int(random() * Float(Self.chords.count)) % Self.chords.count }
            chord = next
            setChord(bank: 1 - active, chord: next)
            target[active] = 0
            target[1 - active] = 1
        }
        if clock >= chordLen {
            active = 1 - active
            clock = fadeLen
        }
        for b in 0..<2 {
            level[b] += min(max(target[b] - level[b], -dt / 9), dt / 9)
            let bankGain = sinf(level[b] * .pi / 2) / 6 // equal-power cross-fade
            for v in 0..<6 {
                banks[b][v].lfo += banks[b][v].lfoRate * dt
                let g = bankGain * (0.65 + 0.35 * sinf(2 * .pi * banks[b][v].lfo))
                gains[(b * 6 + v) * 2] = g * banks[b][v].panL
                gains[(b * 6 + v) * 2 + 1] = g * banks[b][v].panR
                for k in 0..<5 { banks[b][v].osc[k].renorm() }
            }
        }
        nextBell -= Self.block
        if nextBell <= 0 {
            let f = Self.freq(Self.bellNotes[Int(random() * Float(Self.bellNotes.count)) % Self.bellNotes.count])
            for (k, ratio) in [Float(1), 2.76, 5.4].enumerated() { bell[k].set(freq: f * ratio, fs: fs, phase: 0) }
            bellEnv = [0.11, 0.04, 0.015]
            bellAttack = 0
            bellPan = 0.2 + 0.6 * random()
            nextBell = Int((8 + 12 * random()) * fs)
        }
        for k in 0..<3 { bell[k].renorm() }
    }

    mutating func next() -> (Float, Float) {
        if phaseInBlock == 0 { control() }
        phaseInBlock = (phaseInBlock + 1) % Self.block
        var l: Float = 0, r: Float = 0
        for b in 0..<2 where level[b] > 0 {
            for v in 0..<6 {
                var x: Float = 0
                for k in 0..<5 { x += banks[b][v].osc[k].next() * Self.partials[k].amp }
                l += x * gains[(b * 6 + v) * 2]
                r += x * gains[(b * 6 + v) * 2 + 1]
            }
        }
        bellAttack = min(bellAttack + 1 / (0.03 * fs), 1) // 30 ms soft strike
        var bl: Float = 0
        for k in 0..<3 {
            bellEnv[k] *= bellDecay[k]
            bl += bell[k].next() * bellEnv[k]
        }
        bl *= bellAttack
        return (l + bl * (1 - bellPan), r + bl * bellPan)
    }
}

/// Plays a NoiseGen on the default output with its own engine. Bassment's taps exclude its own
/// process, so these sounds skip the EQ and play even with the EQ off.
final class Ambience {
    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let gen: UnsafeMutablePointer<NoiseGen> = {
        let p = UnsafeMutablePointer<NoiseGen>.allocate(capacity: 1)
        p.initialize(to: NoiseGen(sampleRate: 48000))
        return p
    }()

    var sound: SleepSound {
        get { gen.pointee.sound }
        set { gen.pointee.sound = newValue; reverb.bypass = newValue != .ambient432 }
    }
    var gain: Float {
        get { gen.pointee.target }
        set { gen.pointee.target = newValue }
    }

    init(sound: SleepSound, gain: Float) throws {
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        // A throw below still runs deinit (all properties are set), which frees the generator.
        guard sr > 0, let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else {
            throw CAError(what: "no output for sleep sounds", code: 0)
        }
        gen.pointee = NoiseGen(sampleRate: Float(sr))
        gen.pointee.sound = sound
        gen.pointee.target = gain
        let g = gen
        let src = AVAudioSourceNode(format: fmt) { _, _, frames, data in
            let b = UnsafeMutableAudioBufferListPointer(data)
            guard b.count >= 2, let l = b[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = b[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            g.pointee.render(l: l, r: r, frames: Int(frames))
            return noErr
        }
        reverb.loadFactoryPreset(.cathedral)
        reverb.wetDryMix = 45
        reverb.bypass = sound != .ambient432 // the noises are already diffuse
        engine.attach(src)
        engine.attach(reverb)
        engine.connect(src, to: reverb, format: fmt)
        engine.connect(reverb, to: engine.mainMixerNode, format: fmt)
        try engine.start()
    }

    deinit {
        engine.stop() // the render thread must stop before the generator is freed
        gen.deinitialize(count: 1)
        gen.deallocate()
    }
}
