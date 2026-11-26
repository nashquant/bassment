import AppKit
import AVFoundation
import CoreAudio
import CoreAudioKit
import SwiftUI

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
    @Published private(set) var status = "Iniciando"
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

    // MARK: Presets

    var index: Int { settings.presets.firstIndex { $0.id == settings.current } ?? 0 }
    var preset: Preset {
        get { settings.presets[index] }
        set { settings.presets[index] = newValue }
    }

    func selectPreset(_ id: UUID) {
        guard id != settings.current else { return }
        let hadPlugins = !preset.plugins.isEmpty
        settings.current = id
        if hadPlugins || !preset.plugins.isEmpty { rebuild() }
    }

    func newPreset() {
        let p = Preset(name: "Novo \(settings.presets.count + 1)")
        settings.presets.append(p)
        selectPreset(p.id)
    }

    func duplicatePreset() {
        if let p = pipeline { savePluginStates(from: p) }
        var p = preset
        p.id = UUID()
        p.name += " (cópia)"
        settings.presets.append(p)
        selectPreset(p.id)
    }

    func deletePreset() {
        guard settings.presets.count > 1 else { return }
        let id = preset.id
        let hadPlugins = !preset.plugins.isEmpty
        settings.presets.removeAll { $0.id == id }
        settings.deviceMap = settings.deviceMap.filter { $0.value != id }
        settings.current = settings.presets[0].id
        if hadPlugins || !preset.plugins.isEmpty { rebuild() }
    }

    var isLinked: Bool { settings.deviceMap[outputUID] == settings.current }

    func toggleLink() {
        settings.deviceMap[outputUID] = isLinked ? nil : settings.current
    }

    // MARK: Bands

    func addBand() {
        guard preset.bands.count < maxBands else { return }
        preset.bands.append(Band())
    }

    func removeBand(_ id: UUID) { preset.bands.removeAll { $0.id == id } }

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

    // MARK: Plugins

    func addPlugin(_ c: AVAudioUnitComponent) {
        let d = c.audioComponentDescription
        preset.plugins.append(Plugin(name: c.name, type: d.componentType, subType: d.componentSubType,
                                     manufacturer: d.componentManufacturer))
        rebuild()
    }

    func removePlugin(_ id: UUID) {
        windows.removeValue(forKey: id)?.close()
        preset.plugins.removeAll { $0.id == id }
        rebuild()
    }

    func openPlugin(_ id: UUID) {
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let unit = pipeline?.plugins.first(where: { $0.id == id })?.unit else { return }
        let name = preset.plugins.first { $0.id == id }?.name ?? "Plugin"
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
        guard settings.enabled else { status = "Desligado"; return }
        do {
            let p = try await Pipeline.make(output: CA.defaultOutput, preset: preset, appVolumes: settings.appVolumes,
                                            processes: processes, analyzer: analyzer)
            pipeline = p
            sampleRate = p.sampleRate
            status = p.failedPlugins.isEmpty ? "Ativo" : "Falhou: \(p.failedPlugins.joined(separator: ", "))"
            if debug {
                NSLog("Timbre: taps=%@ inputs=%@ sr=%.0f", "\(p.tapBundles)", "\(CA.inputLayout(p.aggregate))", p.sampleRate)
            }
        } catch {
            status = "Erro: \(error)"
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
        outputName = CA.string(id, kAudioObjectPropertyName) ?? "?"
        guard uid != outputUID || pipeline == nil else { return }
        outputUID = uid
        if let mapped = settings.deviceMap[uid], mapped != settings.current,
           settings.presets.contains(where: { $0.id == mapped }) {
            settings.current = mapped
        }
        rebuild()
    }

    private func tick() {
        processes = AppProcess.all()
        if debug {
            let level = (0..<Analyzer.size).reduce(Float(0)) { max($0, abs(analyzer.ring[$1])) }
            NSLog("Timbre: pico=%.4f", level)
        }
        // An app with a custom volume started playing after the last build: give it its own tap.
        guard !rebuilding, let p = pipeline else { return }
        if processes.contains(where: { settings.appVolumes[$0.bundle] != nil && !p.tappedProcesses.contains($0.id) }) {
            rebuild()
        }
    }

    private func settingsChanged() {
        if let p = pipeline {
            p.apply(preset)
            for (b, v) in settings.appVolumes { p.setGain(bundle: b, v) }
        }
        saveItem?.cancel()
        let s = settings
        let item = DispatchWorkItem {
            do { try s.save() } catch { NSLog("Timbre: salvar falhou: %@", "\(error)") }
        }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
