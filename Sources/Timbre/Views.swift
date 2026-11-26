import SwiftUI

struct TimbreApp: App {
    @StateObject private var c = Controller()

    var body: some Scene {
        MenuBarExtra("Timbre", systemImage: "slider.vertical.3") {
            MainView(c: c)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MainView: View {
    @ObservedObject var c: Controller

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                presetBar
                EQGraph(c: c)
                bands
                Divider()
                room
                Divider()
                plugins
                Divider()
                apps
                HStack {
                    Text("Limitador sempre ligado no fim da cadeia.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sair") { NSApp.terminate(nil) }
                }
            }
            .padding(12)
        }
        .frame(width: 500, height: 760)
    }

    private var header: some View {
        HStack {
            Toggle("Timbre", isOn: $c.settings.enabled)
                .toggleStyle(.switch)
                .onChange(of: c.settings.enabled) { c.rebuild() }
            Spacer()
            VStack(alignment: .trailing) {
                Text(c.status).font(.caption)
                Text("Saída: \(c.outputName)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var presetBar: some View {
        HStack {
            Picker("Preset", selection: Binding(get: { c.settings.current ?? c.preset.id }, set: c.selectPreset)) {
                ForEach(c.settings.presets) { Text($0.name).tag($0.id) }
            }
            .frame(width: 190)
            TextField("Nome", text: $c.preset.name).frame(width: 110)
            Menu {
                Button("Novo", action: c.newPreset)
                Button("Duplicar", action: c.duplicatePreset)
                Button("Apagar", action: c.deletePreset).disabled(c.settings.presets.count < 2)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 30)
            Toggle("Desta saída", isOn: Binding(get: { c.isLinked }, set: { _ in c.toggleLink() }))
                .help("Usar este preset sempre que \(c.outputName) for a saída")
        }
    }

    private var bands: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pré-ganho").frame(width: 70, alignment: .leading)
                Slider(value: $c.preset.preamp, in: -24...6)
                Text(String(format: "%+.1f dB", c.preset.preamp)).monospacedDigit().frame(width: 60)
            }
            ForEach($c.preset.bands) { $b in
                HStack(spacing: 6) {
                    Toggle("", isOn: $b.on).labelsHidden()
                    Picker("", selection: $b.kind) {
                        ForEach(FilterKind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 96)
                    TextField("Hz", value: $b.freq, format: .number.precision(.fractionLength(0))).frame(width: 58)
                    if b.kind.hasGain {
                        Slider(value: $b.gain, in: -18...18)
                        Text(String(format: "%+.1f", b.gain)).monospacedDigit().frame(width: 38)
                    } else {
                        Spacer()
                    }
                    if b.kind.hasQ {
                        TextField("Q", value: $b.q, format: .number.precision(.fractionLength(2))).frame(width: 44)
                    }
                    Button { c.removeBand(b.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Adicionar banda", systemImage: "plus", action: c.addBand)
                .disabled(c.preset.bands.count >= maxBands)
        }
    }

    private var room: some View {
        HStack {
            Picker("Sala", selection: $c.preset.room) {
                ForEach(Room.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 220)
            Slider(value: $c.preset.roomMix, in: 0...100).disabled(c.preset.room == .off)
            Text("\(Int(c.preset.roomMix))%").monospacedDigit().frame(width: 40)
        }
    }

    private var plugins: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plugins (Audio Units)").font(.headline)
            ForEach($c.preset.plugins) { $p in
                HStack {
                    Toggle("", isOn: $p.on).labelsHidden()
                    Text(p.name)
                    Spacer()
                    Button("Abrir") { c.openPlugin(p.id) }
                    Button { c.removePlugin(p.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Menu("Adicionar plugin") {
                ForEach(c.components, id: \.self) { comp in
                    Button("\(comp.manufacturerName) · \(comp.name)") { c.addPlugin(comp) }
                }
            }
            .frame(width: 180)
        }
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Volume por app").font(.headline)
            if c.appRows.isEmpty {
                Text("Nenhum app tocando agora.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(c.appRows) { row in
                HStack {
                    Text(row.name).lineLimit(1).frame(width: 140, alignment: .leading)
                    Slider(value: c.volume(row.bundle), in: 0...1) { editing in
                        if !editing { c.volumeCommitted(row.bundle) }
                    }
                    Text("\(Int((c.settings.appVolumes[row.bundle] ?? 1) * 100))%").monospacedDigit().frame(width: 40)
                    Button { c.resetVolume(row.bundle) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .disabled(c.settings.appVolumes[row.bundle] == nil)
                        .help("Voltar ao volume normal")
                }
            }
        }
    }
}

struct EQGraph: View {
    @ObservedObject var c: Controller
    @StateObject private var d = DragState()
    private let range: Double = 18

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                Canvas { ctx, size in draw(ctx, size) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag($0.location, geo.size) }
                .onEnded { _ in d.id = nil; d.started = false })
        }
        .frame(height: 200)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func x(_ f: Double, _ w: CGFloat) -> CGFloat { CGFloat(log(f / 20) / log(1000)) * w }
    private func freq(_ x: CGFloat, _ w: CGFloat) -> Double { 20 * pow(1000, Double(x / w)) }
    private func y(_ g: Double, _ h: CGFloat) -> CGFloat { h / 2 - CGFloat(g / range) * h / 2 }

    private func draw(_ ctx: GraphicsContext, _ s: CGSize) {
        var grid = Path()
        for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
            grid.move(to: CGPoint(x: x(f, s.width), y: 0))
            grid.addLine(to: CGPoint(x: x(f, s.width), y: s.height))
        }
        for g in stride(from: -12.0, through: 12, by: 6) {
            grid.move(to: CGPoint(x: 0, y: y(g, s.height)))
            grid.addLine(to: CGPoint(x: s.width, y: y(g, s.height)))
        }
        ctx.stroke(grid, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
        for (f, label) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
            ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: x(f, s.width) + 10, y: s.height - 8))
        }

        // Spectrum: -90…0 dBFS over the full height.
        let pts = max(16, Int(s.width / 3))
        let spec = c.analyzer.spectrum(points: pts, fs: c.sampleRate)
        var area = Path()
        area.move(to: CGPoint(x: 0, y: s.height))
        for (i, db) in spec.enumerated() {
            let py = s.height - CGFloat((Double(db) + 90) / 90) * s.height
            area.addLine(to: CGPoint(x: CGFloat(i) / CGFloat(pts) * s.width, y: min(s.height, max(0, py))))
        }
        area.addLine(to: CGPoint(x: s.width, y: s.height))
        ctx.fill(area, with: .color(.cyan.opacity(0.18)))

        // EQ response.
        let p = c.preset
        var curve = Path()
        for px in stride(from: CGFloat(0), through: s.width, by: 2) {
            let pt = CGPoint(x: px, y: y(responseDB(p, at: freq(px, s.width), fs: c.sampleRate), s.height))
            px == 0 ? curve.move(to: pt) : curve.addLine(to: pt)
        }
        ctx.stroke(curve, with: .color(.orange), lineWidth: 2)

        for (i, b) in p.bands.enumerated() {
            let pt = CGPoint(x: x(Double(b.freq), s.width), y: y(b.kind.hasGain ? Double(b.gain) : 0, s.height))
            let r: CGFloat = d.id == b.id ? 8 : 6
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(b.on ? .orange : .gray))
            ctx.draw(Text("\(i + 1)").font(.system(size: 8)).foregroundStyle(.black), at: pt)
        }
    }

    private func drag(_ loc: CGPoint, _ s: CGSize) {
        if !d.started {
            d.started = true
            d.id = c.preset.bands.min { dist($0, loc, s) < dist($1, loc, s) }
                .flatMap { dist($0, loc, s) < 20 ? $0.id : nil }
        }
        guard let id = d.id, let i = c.preset.bands.firstIndex(where: { $0.id == id }) else { return }
        var b = c.preset.bands[i]
        b.freq = Float(min(max(freq(loc.x, s.width), 20), 20000)).rounded()
        if b.kind.hasGain {
            b.gain = Float(min(max((s.height / 2 - loc.y) / (s.height / 2) * range, -range), range) * 10).rounded() / 10
        }
        c.preset.bands[i] = b
    }

    private func dist(_ b: Band, _ p: CGPoint, _ s: CGSize) -> CGFloat {
        hypot(x(Double(b.freq), s.width) - p.x, y(b.kind.hasGain ? Double(b.gain) : 0, s.height) - p.y)
    }
}

/// `@State` is a macro whose plugin ships only with Xcode; a plain object avoids it.
final class DragState: ObservableObject {
    var id: UUID?
    var started = false
}
