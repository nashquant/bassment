import AppKit
import CoreAudio
import Foundation
import SwiftUI

if CommandLine.arguments.contains("--selftest") {
    exit(selfTest() ? 0 : 1)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { snapshot(prefix: CommandLine.arguments[i + 1]) }
    exit(0)
}

/// Renders the menu bar panel to PNGs (idle and playing, light and dark) to check layout without screen recording.
@MainActor func snapshot(prefix: String) {
    _ = NSApplication.shared
    Controller.passive = true
    let c = Controller()
    c.settings.sleepSound = SleepSound.ambient432.rawValue
    c.settings.sleepMinutes = 30
    c.settings.sleepLevel = 0 // silent while "playing"
    func render(_ name: String, _ scheme: ColorScheme) {
        let host = NSHostingView(rootView: QuickView(c: c).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
    }
    render("idle", .light)
    c.toggleSleep()
    render("playing", .light)
    render("playing-dark", .dark)
    c.toggleSleep()
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
    var steady = AutoEQ()
    for _ in 0..<100 { steady.update(low: -3, high: -12, dt: 2) }
    expect(steady.bass == 0 && steady.treble == 0, "auto: a track like the usual leaves EQ alone")
    var boomy = steady
    for _ in 0..<5 { boomy.update(low: 3, high: -12, dt: 2) }
    expect(boomy.bass < 0 && boomy.bass >= -5 && boomy.treble == 0, "auto: bass-heavy track gets less bass, slowly")
    var fresh = AutoEQ()
    for i in 0..<29 { fresh.update(low: i % 2 == 0 ? 6 : -6, high: -12, dt: 2) }
    expect(fresh.bass == 0 && abs(fresh.reference![0]) < 0.5, "auto: no correction in the first minute; reference is the mean")
    for _ in 0..<60 { boomy.update(low: 9, high: -12, dt: 2) }
    expect(boomy.bass >= -AutoEQ.limit - 0.001 && boomy.bass < -4, "auto: correction capped at the limit")
    expect(NoiseGen.breathPeriod(after: 0) == 10 && abs(NoiseGen.breathPeriod(after: 600) - 11.65) < 0.01
           && NoiseGen.breathPeriod(after: 3600) == 13.3, "breathing: 6/min, slowing to 4.5/min over 20 min")
    for sound in SleepSound.allCases {
        let music = sound == .ambient432 || sound == .lofi // ambient fades in for 9 s; music is partly shared by both ears
        var g = NoiseGen(sampleRate: 48000)
        g.sound = sound
        g.target = 1
        let n = 48000 * (music ? 30 : 5), from = music ? 48000 * 10 : 24000
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate(); r.deallocate() }
        g.render(l: l, r: r, frames: n)
        var ll = 0.0, rr = 0.0, lr = 0.0
        for i in from..<n { ll += Double(l[i] * l[i]); rr += Double(r[i] * r[i]); lr += Double(l[i] * r[i]) }
        let rms = (ll / Double(n - from)).squareRoot(), corr = lr / (ll * rr).squareRoot()
        expect(abs(l[0]) < 0.01 && (0..<n).allSatisfy { l[$0].isFinite && abs(l[$0]) <= 1 }
               && (music ? rms > 0.04 && rms < 0.14 : rms > 0.07 && rms < 0.16 && abs(corr) < 0.2),
               "sleep \(sound.rawValue): fades in, level in range\(music ? "" : ", wide stereo")")
    }
    return ok
}
