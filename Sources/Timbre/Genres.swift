import Foundation

/// Built-in one-click styles. Curves are starting points by ear, not measurements.
struct Genre: Identifiable {
    let id: String
    let name: String
    let base: [Band]

    /// Owner ID for the pipeline when a built-in genre (which has no plugins) is active.
    static let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Speakers: a 2.1 soundbar booms around 80–120 Hz in a room, so deep sub boost wastes headroom
    /// and muddies; distance also dulls the top end.
    func bands(for kind: OutputKind) -> [Band] {
        guard kind == .speakers else { return base }
        return base.map { b in
            var b = b
            if b.kind == .lowShelf, b.freq < 90 {
                b.freq = 90
                b.gain *= 0.75
            }
            if b.kind == .highShelf { b.gain += 1 }
            return b
        }
    }

    static func find(_ id: String) -> Genre? { all.first { $0.id == id } }

    static let all: [Genre] = [
        Genre(id: "flat", name: "Flat", base: []),
        Genre(id: "bass", name: "Mais graves", base: [ls(90, 6), pk(250, -1, 1)]),
        Genre(id: "jazz", name: "Jazz", base: [ls(100, 2), pk(400, -1, 1), pk(3000, 1.5, 1), hs(10000, 2)]),
        Genre(id: "blues", name: "Blues", base: [ls(120, 3), pk(800, 1.5, 0.8), pk(3000, 1, 1), hs(10000, 1)]),
        Genre(id: "electronic", name: "Eletrônica", base: [ls(60, 6), pk(250, -2, 1), pk(5000, 1, 1), hs(12000, 3)]),
        Genre(id: "funk", name: "Funk", base: [ls(70, 7), pk(300, -2, 1), pk(2500, 2, 1), hs(10000, 1)]),
        Genre(id: "hiphop", name: "Hip-hop", base: [ls(60, 6), pk(200, -1, 1), pk(3000, 1.5, 1), hs(10000, 1)]),
        Genre(id: "rock", name: "Rock", base: [ls(100, 3), pk(500, -1.5, 1), pk(3000, 2.5, 1), hs(10000, 2)]),
        Genre(id: "pop", name: "Pop", base: [ls(100, 3), pk(2500, 1.5, 1), hs(10000, 2.5)]),
        Genre(id: "classical", name: "Clássica", base: [ls(100, 1), pk(2000, -1, 0.7), hs(8000, 1.5)]),
        Genre(id: "voice", name: "Voz", base: [Band(kind: .highPass, freq: 80), pk(250, -2, 1), pk(3000, 3, 1), hs(10000, -1)]),
    ]
}

private func ls(_ f: Float, _ g: Float) -> Band { Band(kind: .lowShelf, freq: f, gain: g) }
private func hs(_ f: Float, _ g: Float) -> Band { Band(kind: .highShelf, freq: f, gain: g) }
private func pk(_ f: Float, _ g: Float, _ q: Float) -> Band { Band(kind: .peak, freq: f, gain: g, q: q) }

// MARK: - Headphone correction (AutoEQ)

/// Parses an AutoEQ "ParametricEQ.txt". The file's own preamp is ignored: Timbre computes one.
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

/// Applied automatically the first time a matching device shows up.
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
