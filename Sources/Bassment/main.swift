import CoreAudio
import Foundation

if CommandLine.arguments.contains("--selftest") {
    exit(selfTest() ? 0 : 1)
}
BassmentApp.main()

/// Checks the pure logic: Q conversion, EQ curve math, tap mixing, settings round trip.
func selfTest() -> Bool {
    var ok = true
    func expect(_ cond: Bool, _ what: String) {
        print(cond ? "ok   \(what)" : "FAIL \(what)")
        ok = ok && cond
    }

    expect(abs(qToOctaves(1.4142) - 1) < 0.01, "Q 1.414 = 1 octave")
    expect(abs(qToOctaves(graphicQ) - 0.5) < 0.01, "graphic band Q = 0.5 octave")

    let flat = Preset(name: "t", bands: [Band(kind: .peak, freq: 1000, gain: 0, q: 1)])
    expect(abs(responseDB(flat, at: 1000, fs: 48000)) < 1e-6, "0 dB peak is flat")
    let peak = Preset(name: "t", bands: [Band(kind: .peak, freq: 1000, gain: 6, q: 1)])
    expect(abs(responseDB(peak, at: 1000, fs: 48000) - 6) < 0.01, "+6 dB peak at 1 kHz")
    let shelf = Preset(name: "t", preamp: -3, bands: [Band(kind: .lowShelf, freq: 100, gain: 6)])
    expect(abs(responseDB(shelf, at: 20, fs: 48000) - 3) < 0.3, "low shelf +6 with -3 preamp = +3 dB at 20 Hz")
    expect(abs(responseDB(shelf, at: 10000, fs: 48000) + 3) < 0.1, "low shelf leaves 10 kHz alone")

    let boost = Preset(name: "t", bands: graphicBands(Genre.find("bassBooster")!.gains))
    let at32 = responseDB(boost, at: 32, fs: 48000), at4k = responseDB(boost, at: 4000, fs: 48000)
    expect(at32 > 10.5 && at32 < 13 && abs(at4k) < 0.5, "Bass Booster: ~+11 dB at 32 Hz, flat at 4 kHz")
    expect(basicOffsets(bass: 5, mid: 1, treble: -2) == [5, 5, 5, 1, 1, 1, 1, -2, -2, -2], "Bass/Mid/Treble map 3/4/3 bands")

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
    expect((0..<frames).allSatisfy { l[$0] == 3 && r[$0] == 4 }, "mixTaps sums taps with gain")

    let out = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    let outABL = AudioBufferList.allocate(maximumBuffers: 1)
    outABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 32, mData: out)
    writeOutput(outABL, l: l, r: r, frames: frames)
    expect(out[0] == 3 && out[1] == 4 && out[6] == 3 && out[7] == 4, "writeOutput interleaves L/R")

    var s = Settings()
    s.appVolumes["com.spotify.client"] = 0.5
    s.presets = [Preset(name: "p", plugins: [Plugin(name: "x", type: 1, subType: 2, manufacturer: 3)])]
    var prof = DeviceProfile(kind: .headphones)
    prof.correctionOn = true
    s.devices["uid"] = prof
    s.bass = 4
    s.style = "bassBooster"
    let back = try? JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
    expect(back?.appVolumes["com.spotify.client"] == 0.5 && back?.presets[0].plugins.first?.subType == 2
           && back?.bass == 4 && back?.style == "bassBooster"
           && back?.devices["uid"]?.correctionOn == true && back?.devices["uid"]?.kind == .headphones,
           "settings JSON round trip")
    let partial = try? JSONDecoder().decode(Settings.self, from: Data(#"{"appVolumes":{"a":0.3}}"#.utf8))
    expect(partial?.appVolumes["a"] == 0.3 && partial?.enabled == true && partial?.avoidClipping == false
           && partial?.style == "flat" && partial?.favorites == ["bassBooster", "dance", "rock", "rnb", "vocalBooster"]
           && partial!.favorites.allSatisfy { Genre.find($0) != nil },
           "missing settings fields fall back to defaults")

    let parsed = parseAutoEQ(knownCorrections[0].text)
    expect(parsed.count == 10 && parsed[0].kind == .lowShelf && parsed[1].freq == 9465 && parsed[1].q == 3.34,
           "AutoEQ parse")


    let boosted = [Band(kind: .lowShelf, freq: 90, gain: 9), Band(kind: .peak, freq: 3000, gain: 4, q: 1)]
    let pre = autoPreamp(boosted)
    let top = (0..<200).map { responseDB(Preset(name: "", preamp: pre, bands: boosted),
                                         at: 20 * pow(1000, Double($0) / 199), fs: 48000) }.max()!
    expect(pre < -8 && top <= 0.05, "avoid clipping keeps the peak at 0 dB")
    return ok
}
