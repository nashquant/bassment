import AVFoundation
import CoreAudio
import Foundation

struct AppProcess: Identifiable, Hashable {
    let id: AudioObjectID
    let pid: pid_t
    let bundle: String
    let playing: Bool

    static func all() -> [AppProcess] {
        let me = getpid()
        return CA.list(systemObject, kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            let pid = CA.prop(obj, kAudioProcessPropertyPID, pid_t(0)) ?? 0
            guard pid != me, let b = CA.string(obj, kAudioProcessPropertyBundleID), !b.isEmpty else { return nil }
            let playing = (CA.prop(obj, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
            return AppProcess(id: obj, pid: pid, bundle: b, playing: playing)
        }
    }
}

/// One live audio graph: taps → aggregate device → IOProc → AVAudioEngine (manual render) → output device.
/// Structural changes (output, tapped apps, plugin list) build a new Pipeline; parameters change live.
final class Pipeline {
    static let maxFrames = 4096
    static let maxTaps = 64

    let presetID: UUID
    let outputUID: String
    private(set) var sampleRate: Double = 48000
    private(set) var tapBundles: [String?] = []          // nil = global tap
    private(set) var tappedProcesses: Set<AudioObjectID> = []
    private(set) var plugins: [(id: UUID, unit: AVAudioUnit)] = []
    private(set) var failedPlugins: [String] = []
    private(set) var aggregate = AudioObjectID(0)

    private var taps: [AudioObjectID] = []
    private var tapUIDs: [String] = []
    private var procID: AudioDeviceIOProcID?
    private var lastRoom: Room?
    private let gains = UnsafeMutablePointer<Float>.allocate(capacity: maxTaps)
    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: maxBands)
    private let reverb = AVAudioUnitReverb()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private let inBuf = AudioBufferList.allocate(maximumBuffers: 2)
    private let outBuf = AudioBufferList.allocate(maximumBuffers: 2)

    @MainActor
    static func make(output: AudioObjectID, preset: Preset, appVolumes: [String: Float],
                     processes: [AppProcess], analyzer: Analyzer) async throws -> Pipeline {
        guard let uid = CA.string(output, kAudioDevicePropertyDeviceUID) else {
            throw CAError(what: "saída padrão não encontrada", code: 0)
        }
        let p = Pipeline(presetID: preset.id, outputUID: uid)
        do {
            // HAL calls can block for a long time (the first one waits on the permission prompt): keep them off the UI thread.
            try await Task.detached {
                try p.createTaps(appVolumes: appVolumes, processes: processes)
                try p.createAggregate()
            }.value
            await p.loadPlugins(preset.plugins)
            try await Task.detached {
                try p.startEngine(preset: preset)
                try p.startIO(analyzer: analyzer)
            }.value
        } catch {
            p.stop()
            throw error
        }
        return p
    }

    private init(presetID: UUID, outputUID: String) {
        self.presetID = presetID
        self.outputUID = outputUID
        gains.initialize(repeating: 1, count: Self.maxTaps)
        for buf in [inBuf, outBuf] {
            for i in 0..<2 {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
                data.initialize(repeating: 0, count: Self.maxFrames)
                buf[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Self.maxFrames * 4), mData: data)
            }
        }
    }

    deinit {
        stop()
        gains.deallocate()
        for buf in [inBuf, outBuf] {
            for b in buf { b.mData?.deallocate() }
            free(buf.unsafeMutablePointer)
        }
    }

    // MARK: Build

    private func createTaps(appVolumes: [String: Float], processes: [AppProcess]) throws {
        let own = CA.processObject(pid: getpid())
        // Without our own process object the global tap would capture our output: feedback.
        guard own != 0 else { throw CAError(what: "processo do Timbre não registrado no Core Audio", code: 0) }
        var custom: [String: [AudioObjectID]] = [:]
        for p in processes where appVolumes[p.bundle] != nil { custom[p.bundle, default: []].append(p.id) }

        let excluded = [own] + custom.values.flatMap { $0 }
        try addTap(CATapDescription(stereoGlobalTapButExcludeProcesses: excluded),
                   bundle: nil, gain: 1)
        for (bundle, objs) in custom.sorted(by: { $0.key < $1.key }) where taps.count < Self.maxTaps {
            try addTap(CATapDescription(stereoMixdownOfProcesses: objs),
                       bundle: bundle, gain: appVolumes[bundle] ?? 1)
            tappedProcesses.formUnion(objs)
        }
    }

    private func addTap(_ d: CATapDescription, bundle: String?, gain: Float) throws {
        d.name = "Timbre"
        d.isPrivate = true
        d.muteBehavior = .mutedWhenTapped // apps sound normal again if Timbre stops reading
        var id = AudioObjectID(0)
        try CA.check(AudioHardwareCreateProcessTap(d, &id), "criar tap")
        gains[taps.count] = gain
        taps.append(id)
        tapBundles.append(bundle)
        tapUIDs.append(d.uuid.uuidString)
    }

    private func createAggregate() throws {
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Timbre",
            kAudioAggregateDeviceUIDKey: "local.timbre.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: tapUIDs.map {
                [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true] as [String: Any]
            },
        ]
        try CA.check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate), "criar aggregate device")
        let sr = CA.prop(aggregate, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0
        if sr > 0 { sampleRate = sr }
    }

    @MainActor
    private func loadPlugins(_ list: [Plugin]) async {
        for p in list {
            do {
                let unit = try await AVAudioUnit.instantiate(with: p.desc, options: [])
                if let data = p.state,
                   let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    unit.auAudioUnit.fullState = dict
                }
                plugins.append((p.id, unit))
            } catch {
                failedPlugins.append(p.name)
            }
        }
    }

    private func startEngine(preset: Preset) throws {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CAError(what: "formato de áudio", code: 0)
        }
        try engine.enableManualRenderingMode(.realtime, format: fmt, maximumFrameCount: AVAudioFrameCount(Self.maxFrames))
        let inPtr = UnsafePointer(inBuf.unsafePointer)
        guard engine.inputNode.setManualRenderingInputPCMFormat(fmt, inputBlock: { _ in inPtr }) else {
            throw CAError(what: "entrada do engine", code: 0)
        }
        let chain: [AVAudioNode] = [eq] + plugins.map(\.unit) + [reverb, limiter]
        var prev: AVAudioNode = engine.inputNode
        for node in chain {
            engine.attach(node)
            engine.connect(prev, to: node, format: fmt)
            prev = node
        }
        engine.connect(prev, to: engine.mainMixerNode, format: fmt)
        apply(preset)
        engine.prepare()
        try engine.start()
    }

    private func startIO(analyzer: Analyzer) throws {
        let render = engine.manualRenderingBlock
        let tapCount = taps.count, gains = self.gains, inB = inBuf, outB = outBuf
        let ring = analyzer.ring, head = analyzer.head, maxFrames = Self.maxFrames
        let L = inB[0].mData!.assumingMemoryBound(to: Float.self)
        let R = inB[1].mData!.assumingMemoryBound(to: Float.self)

        try CA.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, inData, _, outData, _ in
            let outs = UnsafeMutableAudioBufferListPointer(outData)
            guard outs.count > 0, outs[0].mNumberChannels > 0 else { return }
            let frames = Int(outs[0].mDataByteSize) / (4 * Int(outs[0].mNumberChannels))
            guard frames <= maxFrames else { writeOutput(outs, l: nil, r: nil, frames: 0); return }

            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            mixTaps(ins, count: tapCount, gains: gains, frames: frames, l: L, r: R)
            let bytes = UInt32(frames * 4)
            for i in 0..<2 {
                inB[i].mDataByteSize = bytes
                outB[i].mDataByteSize = bytes
            }
            var err: OSStatus = noErr
            let ok = render(AVAudioFrameCount(frames), outB.unsafeMutablePointer, &err) == .success
            // If the engine fails, pass the dry mix through instead of going silent.
            let l = ok ? UnsafePointer(outB[0].mData!.assumingMemoryBound(to: Float.self)) : UnsafePointer(L)
            let r = ok ? UnsafePointer(outB[1].mData!.assumingMemoryBound(to: Float.self)) : UnsafePointer(R)
            writeOutput(outs, l: l, r: r, frames: frames)
            Analyzer.write(ring: ring, head: head, l: l, r: r, frames: frames)
        }, "criar IOProc")
        try CA.check(AudioDeviceStart(aggregate, procID), "iniciar áudio")
    }

    // MARK: Live

    func apply(_ p: Preset) {
        eq.globalGain = p.preamp
        for i in 0..<maxBands {
            let band = eq.bands[i]
            guard i < p.bands.count else { band.bypass = true; continue }
            let b = p.bands[i]
            band.filterType = b.kind.av
            band.frequency = min(max(b.freq, 10), Float(sampleRate * 0.45))
            band.gain = b.kind.hasGain ? b.gain : 0
            band.bandwidth = qToOctaves(b.q)
            band.bypass = !b.on
        }
        if p.room != lastRoom {
            lastRoom = p.room
            if let r = p.room.preset { reverb.loadFactoryPreset(r) }
        }
        reverb.bypass = p.room == .off
        reverb.wetDryMix = p.roomMix
        for (id, unit) in plugins {
            unit.auAudioUnit.shouldBypassEffect = !(p.plugins.first { $0.id == id }?.on ?? true)
        }
    }

    func setGain(bundle: String, _ v: Float) {
        for (i, b) in tapBundles.enumerated() where b == bundle { gains[i] = v }
    }

    func pluginStates() -> [UUID: Data] {
        var out: [UUID: Data] = [:]
        for (id, unit) in plugins {
            if let s = unit.auAudioUnit.fullState,
               let d = try? PropertyListSerialization.data(fromPropertyList: s, format: .binary, options: 0) {
                out[id] = d
            }
        }
        return out
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
            self.procID = nil
        }
        if engine.isRunning { engine.stop() }
        if aggregate != 0 {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = 0
        }
        for t in taps { AudioHardwareDestroyProcessTap(t) }
        taps = []
    }
}
