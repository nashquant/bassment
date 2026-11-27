import AVFoundation
import Foundation

enum SleepSound: String, CaseIterable, Identifiable {
    case pink, brown, rain, ocean, tone432
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pink: "Pink noise"
        case .brown: "Brown noise"
        case .rain: "Rain"
        case .ocean: "Ocean"
        case .tone432: "432 Hz tone"
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
    private var tone: Float = 0, sub: Float = 0, lfo: Float = 0
    private let fs: Float, smooth: Float, dropRate: Float, dropDecay: Float, rainLow: Float, rainHigh: Float

    init(sampleRate: Float) {
        fs = sampleRate
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
        case .tone432:
            return 0 // rendered in render(): both channels share the phase
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
            if sound == .tone432 {
                // 432 Hz plus its lower octave, with a slow swell that drifts between the ears.
                tone += 432 / fs; if tone >= 1 { tone -= 1 }
                sub += 216 / fs; if sub >= 1 { sub -= 1 }
                lfo += 0.08 / fs; if lfo >= 1 { lfo -= 1 }
                let x = (sinf(2 * .pi * tone) * 0.6 + sinf(2 * .pi * sub) * 0.4) * 0.15 * gain
                outL[i] = x * (0.75 + 0.25 * sinf(2 * .pi * lfo))
                outR[i] = x * (0.75 + 0.25 * sinf(2 * .pi * (lfo + 0.25)))
                continue
            }
            outL[i] = min(max(sample(&l, env: eL) * gain, -1), 1)
            outR[i] = min(max(sample(&r, env: eR) * gain, -1), 1)
        }
    }
}

/// Plays a NoiseGen on the default output with its own engine. Bassment's taps exclude its own
/// process, so these sounds skip the EQ and play even with the EQ off.
final class Ambience {
    private let engine = AVAudioEngine()
    private let gen: UnsafeMutablePointer<NoiseGen> = {
        let p = UnsafeMutablePointer<NoiseGen>.allocate(capacity: 1)
        p.initialize(to: NoiseGen(sampleRate: 48000))
        return p
    }()

    var sound: SleepSound {
        get { gen.pointee.sound }
        set { gen.pointee.sound = newValue }
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
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)
        try engine.start()
    }

    deinit {
        engine.stop() // the render thread must stop before the generator is freed
        gen.deinitialize(count: 1)
        gen.deallocate()
    }
}
