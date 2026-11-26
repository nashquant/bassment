import AVFoundation
import Foundation

let maxBands = 24

enum FilterKind: String, Codable, CaseIterable, Identifiable {
    case peak, lowShelf, highShelf, lowPass, highPass, bandPass, notch

    var id: String { rawValue }
    var label: String {
        switch self {
        case .peak: "Peak"
        case .lowShelf: "Low shelf"
        case .highShelf: "High shelf"
        case .lowPass: "Low pass"
        case .highPass: "High pass"
        case .bandPass: "Band pass"
        case .notch: "Notch"
        }
    }
    var hasGain: Bool { [.peak, .lowShelf, .highShelf].contains(self) }
    var hasQ: Bool { [.peak, .bandPass, .notch].contains(self) }
    var av: AVAudioUnitEQFilterType {
        switch self {
        case .peak: .parametric
        case .lowShelf: .lowShelf
        case .highShelf: .highShelf
        case .lowPass: .lowPass
        case .highPass: .highPass
        case .bandPass: .bandPass
        case .notch: .bandStop
        }
    }
}

struct Band: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: FilterKind = .peak
    var freq: Float = 1000
    var gain: Float = 0
    var q: Float = 1
    var on = true
}

/// "Spatial audio": simulated listening rooms via Apple's reverb presets.
enum Room: String, Codable, CaseIterable, Identifiable {
    case off, smallRoom, mediumRoom, largeRoom, mediumChamber, mediumHall, largeHall, plate, cathedral

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Desligado"
        case .smallRoom: "Sala pequena"
        case .mediumRoom: "Sala média"
        case .largeRoom: "Sala grande"
        case .mediumChamber: "Câmara"
        case .mediumHall: "Auditório médio"
        case .largeHall: "Auditório grande"
        case .plate: "Plate"
        case .cathedral: "Catedral"
        }
    }
    var preset: AVAudioUnitReverbPreset? {
        switch self {
        case .off: nil
        case .smallRoom: .smallRoom
        case .mediumRoom: .mediumRoom
        case .largeRoom: .largeRoom
        case .mediumChamber: .mediumChamber
        case .mediumHall: .mediumHall
        case .largeHall: .largeHall
        case .plate: .plate
        case .cathedral: .cathedral
        }
    }
}

struct Plugin: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32
    var state: Data?
    var on = true

    var desc: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType,
                                  componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }
}

struct Preset: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var preamp: Float = 0
    var bands: [Band] = []
    var room: Room = .off
    var roomMix: Float = 20
    var plugins: [Plugin] = []
}

struct Settings: Codable {
    var enabled = true
    var presets: [Preset] = [
        Preset(name: "Flat"),
        Preset(name: "Graves", preamp: -6, bands: [Band(kind: .lowShelf, freq: 120, gain: 6)]),
    ]
    var current: UUID?
    var deviceMap: [String: UUID] = [:]   // output device UID → preset
    var appVolumes: [String: Float] = [:] // bundle ID → gain 0…1

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Timbre/settings.json")
    }

    static func load() -> Settings {
        var s = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        if s.presets.isEmpty { s.presets = Settings().presets }
        if !s.presets.contains(where: { $0.id == s.current }) { s.current = s.presets[0].id }
        return s
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url, options: .atomic)
    }
}
