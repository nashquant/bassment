import Accelerate
import CoreAudio
import Foundation

/// AVAudioUnitEQ takes bandwidth in octaves; the UI uses Q.
func qToOctaves(_ q: Float) -> Float {
    min(max(2 / log(2) * asinh(1 / (2 * max(q, 0.1))), 0.05), 5)
}

/// RBJ cookbook magnitude of one band, in dB. Approximates AVAudioUnitEQ for drawing only.
func bandDB(_ b: Band, at f: Double, fs: Double) -> Double {
    guard b.on else { return 0 }
    let f0 = min(Double(b.freq), fs * 0.45)
    let A = pow(10, Double(b.gain) / 40)
    let w0 = 2 * Double.pi * f0 / fs
    let c = cos(w0), s = sin(w0)
    let q = b.kind.hasQ ? Double(max(b.q, 0.1)) : 1 / 2.0.squareRoot()
    let al = s / (2 * q)
    let sa = 2 * A.squareRoot() * al
    let (b0, b1, b2, a0, a1, a2): (Double, Double, Double, Double, Double, Double)
    switch b.kind {
    case .peak: (b0, b1, b2, a0, a1, a2) = (1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A)
    case .lowShelf:
        (b0, b1, b2) = (A * ((A + 1) - (A - 1) * c + sa), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sa))
        (a0, a1, a2) = ((A + 1) + (A - 1) * c + sa, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sa)
    case .highShelf:
        (b0, b1, b2) = (A * ((A + 1) + (A - 1) * c + sa), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sa))
        (a0, a1, a2) = ((A + 1) - (A - 1) * c + sa, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sa)
    case .lowPass: (b0, b1, b2, a0, a1, a2) = ((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al)
    case .highPass: (b0, b1, b2, a0, a1, a2) = ((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al)
    case .bandPass: (b0, b1, b2, a0, a1, a2) = (al, 0, -al, 1 + al, -2 * c, 1 - al)
    case .notch: (b0, b1, b2, a0, a1, a2) = (1, -2 * c, 1, 1 + al, -2 * c, 1 - al)
    }
    let w = 2 * Double.pi * f / fs
    func mag(_ x0: Double, _ x1: Double, _ x2: Double) -> Double {
        let re = x0 + x1 * cos(w) + x2 * cos(2 * w)
        let im = x1 * sin(w) + x2 * sin(2 * w)
        return re * re + im * im
    }
    return 10 * log10(max(mag(b0, b1, b2), 1e-20) / max(mag(a0, a1, a2), 1e-20))
}

func responseDB(_ p: Preset, at f: Double, fs: Double) -> Double {
    Double(p.preamp) + p.bands.reduce(0) { $0 + bandDB($1, at: f, fs: fs) }
}

// MARK: - Real-time helpers (called from the IOProc: no allocation, no locks)

/// Sums the last `count` input buffers (interleaved Float32, one per tap) into l/r with per-tap gain.
func mixTaps(_ ins: UnsafeMutableAudioBufferListPointer, count: Int, gains: UnsafePointer<Float>,
             frames: Int, l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) {
    l.update(repeating: 0, count: frames)
    r.update(repeating: 0, count: frames)
    let first = ins.count - count
    guard first >= 0 else { return }
    for t in 0..<count {
        let b = ins[first + t]
        let ch = Int(b.mNumberChannels)
        guard ch > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let g = gains[t]
        let n = min(frames, Int(b.mDataByteSize) / (4 * ch))
        for i in 0..<n {
            if ch >= 2 {
                l[i] += d[i * ch] * g
                r[i] += d[i * ch + 1] * g
            } else {
                l[i] += d[i] * g
                r[i] += d[i] * g
            }
        }
    }
}

/// Writes l/r into the first output stream; zeroes every other channel and stream.
func writeOutput(_ outs: UnsafeMutableAudioBufferListPointer, l: UnsafePointer<Float>?, r: UnsafePointer<Float>?, frames: Int) {
    for k in 0..<outs.count {
        let b = outs[k]
        let ch = Int(b.mNumberChannels)
        guard ch > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let total = Int(b.mDataByteSize) / 4
        d.update(repeating: 0, count: total)
        guard k == 0, let l, let r else { continue }
        for i in 0..<min(frames, total / ch) {
            if ch >= 2 {
                d[i * ch] = l[i]
                d[i * ch + 1] = r[i]
            } else {
                d[i] = (l[i] + r[i]) / 2
            }
        }
    }
}

// MARK: - Spectrum analyzer

final class Analyzer {
    static let size = 4096
    let ring = UnsafeMutablePointer<Float>.allocate(capacity: size)
    let head = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private let fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    private var smooth: [Float] = []

    init() {
        ring.initialize(repeating: 0, count: Self.size)
        head.initialize(to: 0)
    }

    /// IO thread. Racy by design: the UI reads a slightly torn snapshot at worst.
    static func write(ring: UnsafeMutablePointer<Float>, head: UnsafeMutablePointer<Int>,
                      l: UnsafePointer<Float>, r: UnsafePointer<Float>, frames: Int) {
        var h = head.pointee
        for i in 0..<frames {
            ring[h] = (l[i] + r[i]) * 0.5
            h = (h + 1) & (size - 1)
        }
        head.pointee = h
    }

    func clear() { ring.update(repeating: 0, count: Self.size) }

    /// dBFS (approx.) at `points` log-spaced frequencies from 20 Hz to 20 kHz.
    func spectrum(points: Int, fs: Double) -> [Float] {
        let n = Self.size
        let h = head.pointee
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = ring[(h + i) & (n - 1)] }
        vDSP.multiply(x, window, result: &x)
        var re = [Float](repeating: 0, count: n / 2)
        var im = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        let ref = 20 * log10(Float(n) / 2)
        var out = [Float](repeating: -120, count: points)
        for p in 0..<points {
            let f0 = 20 * pow(1000, Double(p) / Double(points))
            let f1 = 20 * pow(1000, Double(p + 1) / Double(points))
            let b0 = max(1, Int(f0 / fs * Double(n)))
            let b1 = min(n / 2 - 1, max(b0, Int(f1 / fs * Double(n))))
            guard b0 <= b1 else { continue }
            let m = mags[b0...b1].max() ?? 0
            out[p] = 10 * log10(max(m, 1e-12)) - ref
        }
        if smooth.count != points { smooth = out }
        for i in 0..<points { smooth[i] = out[i] > smooth[i] ? out[i] : max(out[i], smooth[i] - 1.5) }
        return smooth
    }
}
