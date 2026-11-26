import Foundation

// MARK: - Graphic EQ

/// 10 AVAudioUnitEQ .parametric bands, bandwidth 0.5 octave, no global gain compensation.
let graphicFreqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
let graphicQ: Float = 2.87 // = 0.5 octave

func graphicBands(_ gains: [Float]) -> [Band] {
    zip(graphicFreqs, gains).map { Band(kind: .peak, freq: $0, gain: $1, q: graphicQ) }
}

/// Bass/Mid/Treble map onto the 10 bands: 3 low, 4 mid, 3 high.
func basicOffsets(bass: Float, mid: Float, treble: Float) -> [Float] {
    [bass, bass, bass, mid, mid, mid, mid, treble, treble, treble]
}

/// Built-in one-click presets.
struct Genre: Identifiable {
    let id: String
    let name: String
    let gains: [Float]

    /// Owner ID for the pipeline when a built-in preset (which has no plugins) is active.
    static let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func find(_ id: String) -> Genre? { all.first { $0.id == id } }

    // Third-party preset values: see NOTICE. Blues and Funk are ours.
    static let all: [Genre] = [
        Genre(id: "flat", name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Genre(id: "bassBooster", name: "Bass Booster", gains: [11, 8.5, 7, 5, 2.5, 0, 0, 0, 0, 0]),
        Genre(id: "acoustic", name: "Acoustic", gains: [-8.3, 9.8, -15.68, 2.1, 18.22, 3.5, 7, 8.2, 7.1, 4.3]),
        Genre(id: "blues", name: "Blues", gains: [5, 4, 3, 3, 1, 1, 3, 3, 3, 2]),
        Genre(id: "classic", name: "Classical", gains: [9.5, 7.5, 6, 5, -3, -3, 0, 4.5, 6.5, 7.5]),
        Genre(id: "dance", name: "Dance", gains: [7.14, 13.1, 9.98, 0, 3.84, 7.3, 10.3, 9.08, 7.18, 0]),
        Genre(id: "deep", name: "Deep", gains: [9.9, 7.1, 3.5, 2, 5.7, 5, 2.9, -4.3, -7.1, -9.2]),
        Genre(id: "electronic", name: "Electronic", gains: [8.5, 7.6, 2.4, 0, -4.3, 4.5, 1.7, 2.5, 7.9, 9.6]),
        Genre(id: "funk", name: "Funk", gains: [10, 9, 6, 2, -2, -1, 2, 3, 2, 1]),
        Genre(id: "hipHop", name: "Hip-Hop", gains: [10, 8.5, 3, 6, -2, -2, 3, -1, 4, 6]),
        Genre(id: "jazz", name: "Jazz", gains: [8, 6, 3, 4.5, -3, -3, 0, 3, 6, 7.5]),
        Genre(id: "latin", name: "Latin", gains: [9, 6, 0, 0, -3, -3, -3, 0, 6, 9]),
        Genre(id: "loudness", name: "Loudness", gains: [12, 8, 0, 0, -4, 0, -2, -10, 10, 2]),
        Genre(id: "lounge", name: "Lounge", gains: [-6, -3, -1, 3, 8, 5, 0, -3, 4, 2]),
        Genre(id: "piano", name: "Piano", gains: [6, 4, 0, 5, 6, 3, 7, 9, 6, 7]),
        Genre(id: "pop", name: "Pop", gains: [-3, -2, 0, 4, 8, 8, 4, 0, -2, -3]),
        Genre(id: "rnb", name: "R&B", gains: [5.24, 13.84, 11.3, 2.66, -4.38, -3, 4.64, 5.3, 6, 7.5]),
        Genre(id: "rock", name: "Rock", gains: [10, 8, 6, 3, -1, -2, 1, 5, 7, 9]),
        Genre(id: "smallSpeakers", name: "Small Speakers", gains: [11, 8.5, 7, 5, 2.5, 0, -2.5, -5, -7, -8.5]),
        Genre(id: "spokenWord", name: "Spoken Word", gains: [-6.92, -0.94, 0, 1.38, 6.92, 9.22, 9.68, 8.56, 5.08, 0]),
        Genre(id: "vocalBooster", name: "Vocal Booster", gains: [-3, -6, -6, 3, 7.5, 7.5, 6, 3, 0, -3]),
        Genre(id: "trebleBooster", name: "Treble Booster", gains: [0, 0, 0, 0, 0, 2.5, 5, 7, 8.5, 11]),
        Genre(id: "bassReducer", name: "Bass Reducer", gains: [-11, -8.5, -7, -5, -2.5, 0, 0, 0, 0, 0]),
        Genre(id: "trebleReducer", name: "Treble Reducer", gains: [0, 0, 0, 0, 0, -2.5, -5, -7, -8.5, -11]),
    ]
}

// MARK: - Headphone correction (AutoEQ)

/// Parses an AutoEQ "ParametricEQ.txt". The file's own preamp is ignored.
func parseAutoEQ(_ text: String) -> [Band] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
        let t = line.split(separator: " ").map(String.init)
        guard t.first == "Filter", let on = t.firstIndex(of: "ON"), on + 1 < t.count else { return nil }
        func num(_ key: String) -> Float? {
            t.firstIndex(of: key).flatMap { $0 + 1 < t.count ? Float(t[$0 + 1]) : nil }
        }
        let kind: FilterKind
        switch t[on + 1] {
        case "PK": kind = .peak
        case "LS", "LSC": kind = .lowShelf
        case "HS", "HSC": kind = .highShelf
        case "LP", "LPQ": kind = .lowPass
        case "HP", "HPQ": kind = .highPass
        case "NO": kind = .notch
        case "BP": kind = .bandPass
        default: return nil
        }
        guard let fc = num("Fc") else { return nil }
        return Band(kind: kind, freq: fc, gain: num("Gain") ?? 0, q: num("Q") ?? 0.71)
    }
}

struct KnownCorrection {
    let match: String   // substring of the output device name
    let source: String
    let text: String
}

/// Offered (off by default) the first time a matching device shows up.
let knownCorrections = [
    // Product ID 0x201D on this Mac = Powerbeats Pro 2. Source: AutoEq results/DHRME/in-ear.
    KnownCorrection(match: "Powerbeats Pro", source: "AutoEQ · Powerbeats Pro 2 (DHRME)", text: """
        Filter 1: ON LSC Fc 105 Hz Gain 0.0 dB Q 0.70
        Filter 2: ON PK Fc 9465 Hz Gain 5.8 dB Q 3.34
        Filter 3: ON PK Fc 329 Hz Gain 2.0 dB Q 0.40
        Filter 4: ON PK Fc 2539 Hz Gain -3.3 dB Q 2.64
        Filter 5: ON PK Fc 1146 Hz Gain -2.0 dB Q 0.87
        Filter 6: ON HSC Fc 10000 Hz Gain 2.8 dB Q 0.70
        Filter 7: ON PK Fc 5858 Hz Gain -2.4 dB Q 2.73
        Filter 8: ON PK Fc 4226 Hz Gain 1.9 dB Q 3.69
        Filter 9: ON PK Fc 50 Hz Gain -0.7 dB Q 2.29
        Filter 10: ON PK Fc 85 Hz Gain 0.4 dB Q 1.88
        """),
]
