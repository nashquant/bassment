import AVFoundation
import Foundation

let maxBands = 32

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
        case .off: "Off"
        case .smallRoom: "Small room"
        case .mediumRoom: "Medium room"
        case .largeRoom: "Large room"
        case .mediumChamber: "Chamber"
        case .mediumHall: "Medium hall"
        case .largeHall: "Large hall"
        case .plate: "Plate"
        case .cathedral: "Cathedral"
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

/// A user preset. Built-in presets live in Genres.swift.
struct Preset: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var preamp: Float = 0
    var bands: [Band] = []
    var room: Room = .off
    var roomMix: Float = 20
    var plugins: [Plugin] = []
}

enum OutputKind: String, Codable, CaseIterable, Identifiable {
    case headphones, speakers
    var id: String { rawValue }
    var label: String { self == .headphones ? "Headphones" : "Speakers" }
}

/// Automatic per-device optimization. The preset and sliders are global (Settings).
struct DeviceProfile: Codable {
    var kind: OutputKind = .speakers
    var correction: [Band] = []
    var correctionSource = ""
    var correctionOn = false

    init(kind: OutputKind) { self.kind = kind }


    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(OutputKind.self, forKey: .kind) ?? .speakers
        correction = try c.decodeIfPresent([Band].self, forKey: .correction) ?? []
        correctionSource = try c.decodeIfPresent(String.self, forKey: .correctionSource) ?? ""
        correctionOn = try c.decodeIfPresent(Bool.self, forKey: .correctionOn) ?? false
    }
}

struct Settings: Codable {
    var enabled = true
    var avoidClipping = false             // off: boosts are not compensated
    var style = "flat"                    // built-in preset id, or "custom:<uuid>"
    var favorites = ["bassBooster", "dance", "rock", "rnb", "vocalBooster"] // shown in the menu bar
    var auto = false
    var autoReference: [Float]?           // learned average balance, see AutoEQ
    var autoSamples = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var presets: [Preset] = []
    var devices: [String: DeviceProfile] = [:] // output device UID → profile
    var appVolumes: [String: Float] = [:]      // bundle ID → gain 0…1

    init() {}

    // Missing keys fall back to defaults, so adding a field never wipes saved settings.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        avoidClipping = try c.decodeIfPresent(Bool.self, forKey: .avoidClipping) ?? false
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "flat"
        favorites = try c.decodeIfPresent([String].self, forKey: .favorites) ?? Settings().favorites
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
        autoReference = try c.decodeIfPresent([Float].self, forKey: .autoReference)
        autoSamples = try c.decodeIfPresent(Int.self, forKey: .autoSamples) ?? 0
        bass = try c.decodeIfPresent(Float.self, forKey: .bass) ?? 0
        mid = try c.decodeIfPresent(Float.self, forKey: .mid) ?? 0
        treble = try c.decodeIfPresent(Float.self, forKey: .treble) ?? 0
        presets = (try? c.decodeIfPresent([Preset].self, forKey: .presets)) ?? []
        devices = (try? c.decodeIfPresent([String: DeviceProfile].self, forKey: .devices)) ?? [:]
        appVolumes = try c.decodeIfPresent([String: Float].self, forKey: .appVolumes) ?? [:]
    }

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bassment/settings.json")
    }

    static func load() -> Settings {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url, options: .atomic)
    }
}
