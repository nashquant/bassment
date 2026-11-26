import AppKit
import AVFoundation
import CoreAudio
import CoreAudioKit
import SwiftUI
import UniformTypeIdentifiers

struct AppRow: Identifiable {
    let bundle: String
    let name: String
    var id: String { bundle }
}

@MainActor
final class Controller: ObservableObject {
    @Published var settings: Settings { didSet { settingsChanged() } }
    @Published private(set) var outputName = "—"
    @Published private(set) var outputUID = ""
    @Published private(set) var processes: [AppProcess] = []
    @Published private(set) var status = "Starting"
    @Published private(set) var sampleRate: Double = 48000

    let analyzer = Analyzer()
    let components: [AVAudioUnitComponent]
    private var pipeline: Pipeline?
    private var rebuildTask: Task<Void, Never>?
    private var rebuilding = false
    private var saveItem: DispatchWorkItem?
    private var windows: [UUID: NSWindow] = [:]
    private var timer: Timer?
    private let debug = ProcessInfo.processInfo.environment["TIMBRE_DEBUG"] != nil

    init() {
        settings = Settings.load()
        components = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap {
            AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription(
                componentType: $0, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0))
        }.sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }

        CA.listen(systemObject, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            Task { @MainActor in self?.outputChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        processes = AppProcess.all()
        outputChanged()
    }

    // MARK: Output device profile

    var device: DeviceProfile {
        get { settings.devices[outputUID] ?? DeviceProfile(kind: .speakers) }
        set { settings.devices[outputUID] = newValue }
    }

    private static func makeProfile(_ id: AudioObjectID, name: String) -> DeviceProfile {
        var p = DeviceProfile(kind: guessKind(id, name: name))
        if let k = knownCorrections.first(where: { name.localizedCaseInsensitiveContains($0.match) }) {
            p.correction = parseAutoEQ(k.text)
            p.correctionSource = k.source
        }
        return p
    }

    /// Bluetooth output with a microphone of the same name = headphones/earbuds; anything else = speakers.
    private static func guessKind(_ id: AudioObjectID, name: String) -> OutputKind {
        let transport = CA.prop(id, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0
        guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else {
            return .speakers
        }
        let hasMic = CA.list(systemObject, kAudioHardwarePropertyDevices).contains {
            CA.string($0, kAudioObjectPropertyName) == name && !CA.inputLayout($0).isEmpty
        }
        return hasMic ? .headphones : .speakers
    }

    func importCorrection() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose an AutoEQ ParametricEQ.txt file"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let bands = parseAutoEQ(text)
        guard !bands.isEmpty else { status = "No AutoEQ filters in that file"; return }
        device.correction = bands
        device.correctionSource = url.deletingPathExtension().lastPathComponent
        device.correctionOn = true
    }

    // MARK: Styles

    var customIndex: Int? {
        guard device.style.hasPrefix("custom:") else { return nil }
        let id = device.style.dropFirst("custom:".count)
        return settings.presets.firstIndex { $0.id.uuidString == id }
    }

    var styleName: String {
        if let i = customIndex { return settings.presets[i].name }
        return Genre.find(device.style)?.name ?? "Flat"
    }

    /// What actually plays: headphone correction + 10-band graphic EQ (preset + Bass/Mid/Treble) + custom bands.
    var effective: Preset {
        let d = device
        var p: Preset
        var gains = [Float](repeating: 0, count: 10)
        if let i = customIndex {
            p = settings.presets[i]
        } else {
            let g = Genre.find(d.style) ?? Genre.all[0]
            p = Preset(id: Genre.ownerID, name: g.name)
            gains = g.gains
        }
        let offsets = basicOffsets(bass: d.bass, mid: d.mid, treble: d.treble)
        gains = zip(gains, offsets).map { $0 + $1 }
        let correction = d.kind == .headphones && d.correctionOn ? d.correction : []
        p.bands = Array((correction + graphicBands(gains) + p.bands.filter(\.on)).prefix(maxBands))
        if settings.avoidClipping { p.preamp += autoPreamp(p.bands) }
        return p
    }

    func selectStyle(_ id: String) {
        guard id != device.style else { return }
        let before = effective.plugins.map(\.id)
        device.style = id
        if effective.plugins.map(\.id) != before { rebuild() }
    }

    /// Copies the current curve into a new editable style.
    func customize() {
        if let p = pipeline { savePluginStates(from: p) }
        var p: Preset
        if let i = customIndex {
            p = settings.presets[i]
            p.id = UUID()
            p.name += " copy"
        } else {
            let g = Genre.find(device.style) ?? Genre.all[0]
            p = Preset(name: "My \(g.name)", bands: graphicBands(g.gains))
        }
        settings.presets.append(p)
        selectStyle("custom:\(p.id.uuidString)")
    }

    func deleteCustom() {
        guard let i = customIndex else { return }
        let hadPlugins = !settings.presets[i].plugins.isEmpty
        let id = "custom:\(settings.presets[i].id.uuidString)"
        settings.presets.remove(at: i)
        for (uid, var prof) in settings.devices where prof.style == id {
            prof.style = "flat"
            settings.devices[uid] = prof
        }
        if hadPlugins { rebuild() }
    }

    var custom: Preset {
        get { customIndex.map { settings.presets[$0] } ?? Preset(name: "") }
        set { if let i = customIndex { settings.presets[i] = newValue } }
    }

    func addBand() {
        guard custom.bands.count < maxBands - 20 else { return }
        custom.bands.append(Band())
    }

    func removeBand(_ id: UUID) { custom.bands.removeAll { $0.id == id } }

    /// Copies the user's own eqMac Advanced EQ presets in (skips names already present).
    func importEqMacPresets() {
        let have = Set(settings.presets.map(\.name))
        let new = eqMacUserPresets().filter { !have.contains($0.name) }
        settings.presets += new
        status = new.isEmpty ? "No new eqMac presets" : "Imported \(new.count) eqMac preset(s)"
    }

    // MARK: Apps

    var appRows: [AppRow] {
        var seen = Set<String>()
        return processes.filter { $0.playing || settings.appVolumes[$0.bundle] != nil }.compactMap { p in
            guard seen.insert(p.bundle).inserted else { return nil }
            let name = NSRunningApplication(processIdentifier: p.pid)?.localizedName ?? p.bundle
            return AppRow(bundle: p.bundle, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func volume(_ bundle: String) -> Binding<Float> {
        Binding(get: { self.settings.appVolumes[bundle] ?? 1 },
                set: { self.settings.appVolumes[bundle] = $0 })
    }

    /// A new app needs its own tap, so the graph is rebuilt once the slider is released.
    func volumeCommitted(_ bundle: String) {
        if pipeline?.tapBundles.contains(bundle) != true { rebuild() }
    }

    func resetVolume(_ bundle: String) {
        settings.appVolumes[bundle] = nil
        rebuild()
    }

    // MARK: Plugins (custom styles only)

    func addPlugin(_ c: AVAudioUnitComponent) {
        guard customIndex != nil else { return }
        let d = c.audioComponentDescription
        custom.plugins.append(Plugin(name: c.name, type: d.componentType, subType: d.componentSubType,
                                     manufacturer: d.componentManufacturer))
        rebuild()
    }

    func removePlugin(_ id: UUID) {
        windows.removeValue(forKey: id)?.close()
        custom.plugins.removeAll { $0.id == id }
        rebuild()
    }

    func openPlugin(_ id: UUID) {
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let unit = pipeline?.plugins.first(where: { $0.id == id })?.unit else { return }
        let name = custom.plugins.first { $0.id == id }?.name ?? "Plugin"
        unit.auAudioUnit.requestViewController { vc in
            Task { @MainActor in
                let controller: NSViewController
                if let vc {
                    controller = vc
                } else {
                    let generic = AUGenericView(audioUnit: unit.audioUnit)
                    generic.frame.size = generic.fittingSize == .zero ? NSSize(width: 420, height: 300) : generic.fittingSize
                    controller = NSViewController()
                    controller.view = generic
                }
                let w = NSWindow(contentViewController: controller)
                w.title = name
                w.isReleasedWhenClosed = false
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in
                        self?.windows[id] = nil
                        if let p = self?.pipeline { self?.savePluginStates(from: p) }
                    }
                }
                self.windows[id] = w
                w.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
    }

    // MARK: Engine

    func rebuild() {
        let prev = rebuildTask
        rebuildTask = Task {
            await prev?.value
            await doRebuild()
        }
    }

    private func doRebuild() async {
        rebuilding = true
        defer { rebuilding = false }
        if let p = pipeline {
            savePluginStates(from: p)
            let open = windows.values
            windows.removeAll()
            open.forEach { $0.close() }
            p.stop()
            pipeline = nil
        }
        analyzer.clear()
        guard settings.enabled else { status = "Off"; return }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.bitgapp.eqmac" }) {
            status = "Quit eqMac first: running both loops the audio"
            return
        }
        do {
            let p = try await Pipeline.make(output: CA.defaultOutput, preset: effective, appVolumes: settings.appVolumes,
                                            processes: processes, analyzer: analyzer)
            pipeline = p
            sampleRate = p.sampleRate
            status = p.failedPlugins.isEmpty ? "Active" : "Failed to load: \(p.failedPlugins.joined(separator: ", "))"
            if debug {
                NSLog("Timbre: taps=%@ inputs=%@ sr=%.0f", "\(p.tapBundles)", "\(CA.inputLayout(p.aggregate))", p.sampleRate)
            }
        } catch {
            status = "Error: \(error)"
            NSLog("Timbre: %@", "\(error)")
        }
    }

    private func savePluginStates(from p: Pipeline) {
        let states = p.pluginStates()
        guard !states.isEmpty, let pi = settings.presets.firstIndex(where: { $0.id == p.presetID }) else { return }
        for i in settings.presets[pi].plugins.indices {
            if let d = states[settings.presets[pi].plugins[i].id] { settings.presets[pi].plugins[i].state = d }
        }
    }

    private func outputChanged() {
        let id = CA.defaultOutput
        let uid = CA.string(id, kAudioDevicePropertyDeviceUID) ?? ""
        let name = CA.string(id, kAudioObjectPropertyName) ?? "?"
        guard uid != outputUID || pipeline == nil else { return }
        outputName = name
        outputUID = uid
        if !uid.isEmpty, settings.devices[uid] == nil { settings.devices[uid] = Self.makeProfile(id, name: name) }
        rebuild()
    }

    private func tick() {
        processes = AppProcess.all()
        if debug {
            let level = (0..<Analyzer.size).reduce(Float(0)) { max($0, abs(analyzer.ring[$1])) }
            NSLog("Timbre: pico=%.4f", level)
        }
        guard !rebuilding else { return }
        guard let p = pipeline else {
            // Retry once the user quits eqMac.
            if settings.enabled, status.hasPrefix("Quit eqMac"),
               !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.bitgapp.eqmac" }) {
                rebuild()
            }
            return
        }
        // An app with a custom volume started playing after the last build: give it its own tap.
        if processes.contains(where: { settings.appVolumes[$0.bundle] != nil && !p.tappedProcesses.contains($0.id) }) {
            rebuild()
        }
    }

    private func settingsChanged() {
        if let p = pipeline {
            p.apply(effective)
            for (b, v) in settings.appVolumes { p.setGain(bundle: b, v) }
        }
        saveItem?.cancel()
        let s = settings
        let item = DispatchWorkItem {
            do { try s.save() } catch { NSLog("Timbre: save failed: %@", "\(error)") }
        }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
