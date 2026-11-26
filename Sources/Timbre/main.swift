import CoreAudio
import Foundation

if CommandLine.arguments.contains("--selftest") {
    exit(selfTest() ? 0 : 1)
}
TimbreApp.main()

/// Checks the pure logic: Q conversion, EQ curve math, tap mixing, settings round trip.
func selfTest() -> Bool {
    var ok = true
    func expect(_ cond: Bool, _ what: String) {
        print(cond ? "ok   \(what)" : "FAIL \(what)")
        ok = ok && cond
    }

    expect(abs(qToOctaves(1.4142) - 1) < 0.01, "Q 1.414 = 1 oitava")

    let flat = Preset(name: "t", bands: [Band(kind: .peak, freq: 1000, gain: 0, q: 1)])
    expect(abs(responseDB(flat, at: 1000, fs: 48000)) < 1e-6, "peak com 0 dB é plano")
    let peak = Preset(name: "t", bands: [Band(kind: .peak, freq: 1000, gain: 6, q: 1)])
    expect(abs(responseDB(peak, at: 1000, fs: 48000) - 6) < 0.01, "peak +6 dB em 1 kHz")
    let shelf = Preset(name: "t", preamp: -3, bands: [Band(kind: .lowShelf, freq: 100, gain: 6)])
    expect(abs(responseDB(shelf, at: 20, fs: 48000) - 3) < 0.3, "low shelf +6 com pré-ganho -3 ≈ +3 dB em 20 Hz")
    expect(abs(responseDB(shelf, at: 10000, fs: 48000) + 3) < 0.1, "low shelf não mexe em 10 kHz")

    // Two stereo taps, interleaved, gains 1 and 0.5.
    let frames = 4
    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    let a = UnsafeMutablePointer<Float>.allocate(capacity: 8), b = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    for i in 0..<8 { a[i] = i % 2 == 0 ? 1 : 2; b[i] = 4 }
    abl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 32, mData: a)
    abl[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 32, mData: b)
    let gains = UnsafeMutablePointer<Float>.allocate(capacity: 2)
    gains[0] = 1; gains[1] = 0.5
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    mixTaps(abl, count: 2, gains: gains, frames: frames, l: l, r: r)
    expect((0..<frames).allSatisfy { l[$0] == 3 && r[$0] == 4 }, "mixTaps soma taps com ganho")

    let out = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    let outABL = AudioBufferList.allocate(maximumBuffers: 1)
    outABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 32, mData: out)
    writeOutput(outABL, l: l, r: r, frames: frames)
    expect(out[0] == 3 && out[1] == 4 && out[6] == 3 && out[7] == 4, "writeOutput intercala L/R")

    var s = Settings()
    s.appVolumes["com.spotify.client"] = 0.5
    s.presets[0].plugins = [Plugin(name: "x", type: 1, subType: 2, manufacturer: 3)]
    let back = try? JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
    expect(back?.appVolumes["com.spotify.client"] == 0.5 && back?.presets[0].plugins.first?.subType == 2,
           "settings ida e volta em JSON")
    return ok
}
