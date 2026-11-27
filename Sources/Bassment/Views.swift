import SwiftUI

struct BassmentApp: App {
    @StateObject private var c: Controller

    /// The "B" from the app icon, as a template so macOS tints it for light/dark menu bars.
    static let menuBarIcon: NSImage = {
        let img = Bundle.main.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: nil)!
        img.isTemplate = true
        img.accessibilityDescription = "Bassment"
        return img
    }()

    init() {
        // Created here, not lazily: with no window at launch, SwiftUI would otherwise build the
        // controller only when a menu or window opens, and audio would not be processed until then.
        let controller = Controller()
        _c = StateObject(wrappedValue: controller)
    }

    var body: some Scene {
        Window("Bassment", id: "main") {
            MainView(c: c)
                .onAppear { c.windowOpen = true }
                .onDisappear { c.windowOpen = false }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed) // start quietly in the menu bar (login item)
        .restorationBehavior(.disabled)      // and do not reopen a window left open at quit
        MenuBarExtra {
            QuickView(c: c)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Shared pieces

struct StyleGrid: View {
    @ObservedObject var c: Controller
    var columns = 4

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(Genre.all) { g in button(g.name, id: g.id) }
            ForEach(c.settings.presets) { p in button(p.name, id: "custom:\(p.id.uuidString)") }
        }
    }

    private func button(_ name: String, id: String) -> some View {
        let selected = c.settings.style == id
        let favorite = c.settings.favorites.contains(id)
        return Button { c.selectStyle(id) } label: {
            HStack(spacing: 3) {
                if favorite { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                Text(name).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .orange : nil)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.orange : .clear, lineWidth: 2))
        .contextMenu {
            Button(favorite ? "Remove from Favorites" : "Add to Favorites") { c.toggleFavorite(id) }
        }
    }
}

struct BasicEQ: View {
    @ObservedObject var c: Controller

    var body: some View {
        VStack(spacing: 4) {
            row("Bass", $c.settings.bass)
            row("Mid", $c.settings.mid)
            row("Treble", $c.settings.treble)
        }
    }

    private func row(_ label: String, _ v: Binding<Float>) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: v, in: -24...24, step: 0.5)
            Text(String(format: "%+.1f dB", v.wrappedValue)).monospacedDigit().frame(width: 62, alignment: .trailing)
        }
    }
}

struct Header: View {
    @ObservedObject var c: Controller

    var body: some View {
        HStack {
            Toggle("On", isOn: $c.settings.enabled)
                .toggleStyle(.switch)
                .onChange(of: c.settings.enabled) { c.rebuild() }
            Spacer()
            Text(c.status).font(.caption).foregroundStyle(c.status == "Active" ? Color.secondary : Color.orange)
        }
    }
}

struct OutputRow: View {
    @ObservedObject var c: Controller

    var body: some View {
        HStack {
            Image(systemName: c.device.kind == .headphones ? "headphones" : "hifispeaker")
            VStack(alignment: .leading, spacing: 1) {
                Text(c.outputName).bold().lineLimit(1)
                Text(c.optimization).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            // Detected automatically; the menu only fixes a wrong guess.
            Menu(c.device.kind.label) {
                ForEach(OutputKind.allCases) { k in Button(k.label) { c.device.kind = k } }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

struct VolumeRow: View {
    @ObservedObject var c: Controller

    var body: some View {
        HStack {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: c.volumeBinding, in: 0...1)
            Text(c.volume.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        .disabled(c.volume == nil)
        .help(c.volume == nil ? "This output has no volume control" : "Output volume")
    }
}

struct SleepPanel: View {
    @ObservedObject var c: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Picker("Sound", selection: $c.settings.sleepSound) {
                    ForEach(SleepSound.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
                Picker("Timer", selection: $c.settings.sleepMinutes) {
                    Text("No timer").tag(0)
                    ForEach([15, 30, 60, 90], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: c.settings.sleepMinutes) { c.restartSleepTimer() }
                Spacer()
                Button { c.toggleSleep() } label: { Image(systemName: c.sleeping ? "stop.fill" : "play.fill") }
                    .help(c.sleeping ? "Stop sleep sounds" : "Play sleep sounds")
            }
            if c.sleeping {
                HStack {
                    Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
                    Slider(value: $c.settings.sleepLevel, in: 0...1)
                }
                Text(c.sleepEnd.map { "Fades out and stops at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Plays until you stop it")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AutoToggle: View {
    @ObservedObject var c: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Auto", isOn: $c.settings.auto)
                .onChange(of: c.settings.auto) { c.autoToggled() }
                .help("Adjusts bass and treble per track toward the balance you usually listen to")
            Text(c.settings.auto
                 ? String(format: "Bass %+.1f dB · Treble %+.1f dB", c.auto.bass, c.auto.treble)
                 : "Balances each track automatically")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - Menu bar

struct QuickView: View {
    @ObservedObject var c: Controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(c: c)
            OutputRow(c: c)
            VolumeRow(c: c)
            Divider()
            VStack(spacing: 2) {
                ForEach(c.favorites, id: \.self) { id in
                    let selected = c.settings.style == id
                    Button { c.selectStyle(id) } label: {
                        HStack {
                            Text(c.name(of: id))
                            Spacer()
                            if selected { Image(systemName: "checkmark").foregroundStyle(.orange) }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .background(selected ? Color.orange.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                if c.favorites.isEmpty {
                    Text("Right-click a preset in the app to add it here.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !c.favorites.contains(c.settings.style) {
                Text("Now: \(c.styleName)").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            AutoToggle(c: c)
            Divider()
            SleepPanel(c: c)
            Divider()
            HStack {
                Button("Open Bassment") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

// MARK: - Main window

struct MainView: View {
    @ObservedObject var c: Controller

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Header(c: c)
                OutputRow(c: c)
                VolumeRow(c: c)

                section("Preset") { StyleGrid(c: c) }
                section("Bass · Mid · Treble") {
                    BasicEQ(c: c)
                    Toggle("Avoid clipping (lowers volume by the largest boost)", isOn: $c.settings.avoidClipping)
                        .font(.callout)
                    AutoToggle(c: c)
                }
                EQGraph(c: c)
                section("Sleep sounds") { SleepPanel(c: c) }
                Text("Preset and sliders apply to every output. Each device gets its own correction automatically. Right-click a preset to add it to the menu bar favorites.")
                    .font(.caption2).foregroundStyle(.secondary)
                DisclosureGroup("Device correction") { correction.padding(.top, 6) }
                DisclosureGroup("Edit preset") { editor.padding(.top, 6) }
                DisclosureGroup("App volume") { apps.padding(.top, 6) }
            }
            .padding(16)
        }
        .frame(width: 560, height: 760)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private var correction: some View {
        HStack {
            Toggle(isOn: $c.device.correctionOn) {
                Text(c.device.correction.isEmpty ? "No correction for these headphones"
                     : "Headphone correction: \(c.device.correctionSource)")
            }
            .disabled(c.device.correction.isEmpty)
            Spacer()
            Button("Import AutoEQ…", action: c.importCorrection)
        }
        .font(.callout)
    }

    @ViewBuilder private var editor: some View {
        if c.customIndex == nil {
            HStack {
                Text("\(c.styleName) is built in.").foregroundStyle(.secondary)
                Button("Make editable copy", action: c.customize)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Name", text: $c.custom.name).frame(width: 200)
                    Button("Duplicate", action: c.customize)
                    Button("Delete", role: .destructive, action: c.deleteCustom)
                }
                Text("Drag the points on the graph, or edit the bands:").font(.caption).foregroundStyle(.secondary)
                bands
                HStack {
                    Picker("Room", selection: $c.custom.room) {
                        ForEach(Room.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 220)
                    Slider(value: $c.custom.roomMix, in: 0...100).disabled(c.custom.room == .off)
                    Text("\(Int(c.custom.roomMix))%").monospacedDigit().frame(width: 40)
                }
                plugins
            }
        }
    }

    private var bands: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($c.custom.bands) { $b in
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
            Button("Add band", systemImage: "plus", action: c.addBand)
        }
    }

    private var plugins: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plugins (Audio Units)").font(.subheadline).bold()
            ForEach($c.custom.plugins) { $p in
                HStack {
                    Toggle("", isOn: $p.on).labelsHidden()
                    Text(p.name)
                    Spacer()
                    Button("Open") { c.openPlugin(p.id) }
                    Button { c.removePlugin(p.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Menu("Add plugin") {
                ForEach(c.components, id: \.self) { comp in
                    Button("\(comp.manufacturerName) · \(comp.name)") { c.addPlugin(comp) }
                }
            }
            .frame(width: 180)
        }
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 6) {
            if c.appRows.isEmpty {
                Text("No app is playing right now.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(c.appRows) { row in
                HStack {
                    Text(row.name).lineLimit(1).frame(width: 150, alignment: .leading)
                    Slider(value: c.volume(row.bundle), in: 0...1) { editing in
                        if !editing { c.volumeCommitted(row.bundle) }
                    }
                    Text("\(Int((c.settings.appVolumes[row.bundle] ?? 1) * 100))%").monospacedDigit().frame(width: 40)
                    Button { c.resetVolume(row.bundle) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .disabled(c.settings.appVolumes[row.bundle] == nil)
                        .help("Back to normal volume")
                }
            }
        }
    }
}

// MARK: - Graph

struct EQGraph: View {
    @ObservedObject var c: Controller
    @StateObject private var d = DragState()
    @Environment(\.appearsActive) private var active
    private let range: Double = 18

    var body: some View {
        GeometryReader { geo in
            // Redraw only while the window is in front: a hidden graph costs CPU for nothing.
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active)) { _ in
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

        // Final curve, preamp excluded so the shape reads around 0 dB.
        var shape = c.effective
        shape.preamp = 0
        var curve = Path()
        for px in stride(from: CGFloat(0), through: s.width, by: 2) {
            let pt = CGPoint(x: px, y: y(responseDB(shape, at: freq(px, s.width), fs: c.sampleRate), s.height))
            px == 0 ? curve.move(to: pt) : curve.addLine(to: pt)
        }
        ctx.stroke(curve, with: .color(.orange), lineWidth: 2)

        guard c.customIndex != nil else { return }
        for (i, b) in c.custom.bands.enumerated() {
            let pt = CGPoint(x: x(Double(b.freq), s.width), y: y(b.kind.hasGain ? Double(b.gain) : 0, s.height))
            let r: CGFloat = d.id == b.id ? 8 : 6
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(b.on ? .orange : .gray))
            ctx.draw(Text("\(i + 1)").font(.system(size: 8)).foregroundStyle(.black), at: pt)
        }
    }

    private func drag(_ loc: CGPoint, _ s: CGSize) {
        guard c.customIndex != nil else { return }
        if !d.started {
            d.started = true
            d.id = c.custom.bands.min { dist($0, loc, s) < dist($1, loc, s) }
                .flatMap { dist($0, loc, s) < 20 ? $0.id : nil }
        }
        guard let id = d.id, let i = c.custom.bands.firstIndex(where: { $0.id == id }) else { return }
        var b = c.custom.bands[i]
        b.freq = Float(min(max(freq(loc.x, s.width), 20), 20000)).rounded()
        if b.kind.hasGain {
            b.gain = Float(min(max((s.height / 2 - loc.y) / (s.height / 2) * range, -range), range) * 10).rounded() / 10
        }
        c.custom.bands[i] = b
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
