// Popover panel shown when the menu bar item is clicked.

import SwiftUI
import ServiceManagement

final class PanelModel: ObservableObject {
    @Published var tick = 0
    var station: Station?
    var connError: String?
    var demo = false
    /// Title shown in the popup header.
    var stationName = "Jackery SolarVault 3"
    var onOpenConfig: () -> Void = {}
    var onReload: () -> Void = {}
    /// Saves a config; returns an error message on failure.
    var onSave: (Config) -> String? = { _ in nil }
    var onLayoutChange: () -> Void = {}
    /// Switches the UI language right away and remembers it in config.json.
    var onLanguage: (Lang) -> Void = { _ in }

    @Published var detail: Metric? { didSet { DispatchQueue.main.async { self.onLayoutChange() } } }
    @Published var detailRange: TimeInterval = 3600
    @Published var showOutages = false { didSet { DispatchQueue.main.async { self.onLayoutChange() } } }
    /// Selected outage (its start time) on the outage page.
    @Published var outageStart: Double? { didSet { DispatchQueue.main.async { self.onLayoutChange() } } }

    @Published var showSettings = false { didSet { DispatchQueue.main.async { self.onLayoutChange() } } }
    @Published var draft = SettingsDraft()
    @Published var settingsError: String? { didSet { DispatchQueue.main.async { self.onLayoutChange() } } }

    func openSettings() {
        draft = Config.loadRaw().map(SettingsDraft.init) ?? SettingsDraft()
        settingsError = nil
        showSettings = true
    }

    func closeSettings() {
        settingsError = nil
        showSettings = false
    }

    func saveSettings() {
        switch draft.build() {
        case .failure(let e): settingsError = e.message
        case .success(let cfg):
            if let err = onSave(cfg) { settingsError = err } else { closeSettings() }
        }
    }
}

enum Palette {
    static let green = Color(red: 0.30, green: 0.82, blue: 0.50)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.25)
    static let red = Color(red: 1.00, green: 0.38, blue: 0.33)
    static let discharge = Color(red: 1.00, green: 0.58, blue: 0.28)

    static func forSoc(_ soc: Double) -> Color { soc >= 50 ? green : soc >= 20 ? amber : red }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let _ = model.tick
        VStack(alignment: .leading, spacing: 14) {
            if model.showSettings {
                SettingsView(model: model)
            } else if model.showOutages, let st = model.station {
                if let start = model.outageStart, let o = st.grid.outage(start: start) {
                    OutageDetailView(model: model, st: st, outage: o)
                } else {
                    OutagesView(model: model, st: st)
                }
            } else if let m = model.detail, let st = model.station {
                DetailView(model: model, st: st, metric: m)
            } else {
            if let st = model.station {
                // Station is a mutable class passed by reference: SwiftUI would treat these
                // views as unchanged and never re-render them, so rebuild them on every data tick.
                Group {
                    Header(st: st, name: model.stationName, error: model.connError, demo: model.demo)
                    Hero(st: st, open: { model.detail = $0 })
                    GridCard(log: st.grid, open: { model.showOutages = true })
                    PowerChart(st: st, open: { model.detail = .battery })
                    Tiles(st: st, open: { model.detail = $0 })
                }
                .id(model.tick)
            } else {
                Unconfigured(open: model.openSettings)
            }
            Footer(st: model.station, model: model)
            }
        }
        .padding(16)
        .frame(width: 344)
    }
}

// MARK: - Header

private struct Header: View {
    let st: Station
    let name: String
    let error: String?
    let demo: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                Text(demo ? L("демо-режим", "demo mode") : st.sn)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(state: state, text: stateText)
        }
    }

    private var state: StatusPill.State {
        if error != nil { return .error }
        if st.lastUpdate == nil || st.isStale { return .waiting }
        return .online
    }

    private var stateText: String {
        if error != nil { return L("немає брокера", "no broker") }
        if st.lastUpdate == nil { return L("чекаємо станцію", "waiting for station") }
        if st.isStale { return Fmt.ago(st.lastUpdate) }
        return L("онлайн", "online")
    }
}

private struct StatusPill: View {
    enum State { case online, waiting, error }
    let state: State
    let text: String

    var color: Color { state == .online ? Palette.green : state == .waiting ? Palette.amber : Palette.red }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}

// MARK: - Hero: SOC ring + runtime

private struct Hero: View {
    let st: Station
    let open: (Metric) -> Void

    var body: some View {
        HStack(spacing: 20) {
            Button { open(.soc) } label: {
                SocRing(soc: st.soc, minSoc: st.minSoc, charging: st.isCharging)
                    .frame(width: 104, height: 104)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("Графік заряду", "Charge chart"))
            VStack(alignment: .leading, spacing: 3) {
                Text(st.isCharging ? L("ДО \(Int(st.maxSoc))%", "TO \(Int(st.maxSoc))%") : L("ЗАПАС", "LEFT"))
                    .font(.system(size: 10, weight: .medium)).kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(st.isCharging ? toFull : runtime)
                    .font(.system(size: 34, weight: .light))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(st.isCharging ? L("заряджається \(Fmt.watts(st.smoothedNet))", "charging at \(Fmt.watts(st.smoothedNet))") : loadText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if st.isCharging {
                    Label(L("запас \(runtime)", "\(runtime) left") + (st.smoothedLoad.map { $0 >= 5 ? L(" при \(Fmt.watts($0))", " at \(Fmt.watts($0))") : "" } ?? ""),
                          systemImage: "bolt.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.green)
                        .padding(.top, 4)
                } else if st.isDischarging {
                    Label(L("розряджається", "discharging"), systemImage: "arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.discharge)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 108)   // constant, so the charging/discharging line doesn't resize the window
    }

    private var toFull: String {
        guard let h = st.toFullHours else { return "—" }
        return h < 1.0 / 60 ? L("повна", "full") : "~" + Fmt.duration(h)
    }

    private var runtime: String {
        guard let h = st.runtimeHours else { return "—" }
        return h.isFinite ? "~" + Fmt.duration(h) : "∞"
    }

    private var loadText: String {
        guard let load = st.smoothedLoad else { return L("немає даних про навантаження", "no load data") }
        return load < 5 ? L("навантаження немає", "no load") : L("при навантаженні \(Fmt.watts(load))", "at \(Fmt.watts(load)) load")
    }
}

private struct SocRing: View {
    let soc: Double?
    let minSoc: Double
    let charging: Bool

    var body: some View {
        let value = (soc ?? 0) / 100
        let color = Palette.forSoc(soc ?? 0)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 9)
            // Reserve below the discharge limit, drawn as a faint segment.
            Circle()
                .trim(from: 0, to: minSoc / 100)
                .stroke(Palette.red.opacity(0.25), style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: value)
                .stroke(AngularGradient(colors: [color.opacity(0.65), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(value, 0.01))),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: value)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(soc.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 32, weight: .light))
                        .monospacedDigit()
                    Text("%").font(.system(size: 14, weight: .light)).foregroundStyle(.secondary)
                }
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(Palette.green)
                } else {
                    Text(L("заряд", "charge")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Battery power chart (last hour)

private struct PowerChart: View {
    let st: Station
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let now = Date().timeIntervalSince1970
        let pts = st.store.buckets(.battery, from: now - 3600, to: now, count: 156) { $0 }
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("Батарея · остання година", "Battery · last hour"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary).opacity(hover ? 1 : 0)
                    Spacer()
                    if let net = st.smoothedNet {
                        Text(net >= 0 ? "+\(Fmt.watts(net))" : "−\(Fmt.watts(-net))")
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(net >= 15 ? Palette.green : net <= -15 ? Palette.discharge : .secondary)
                    }
                }
                ZStack {
                    if pts.compactMap({ $0 }).count < 2 {
                        Text(L("збираю дані…", "collecting data…")).font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else {
                        SeriesChart(points: pts, metric: .battery,
                                    domain: SeriesChart.domain(for: .battery, points: pts, capacityKWh: 0))
                    }
                }
                .frame(height: 58)
                .frame(maxWidth: .infinity)
                HStack {
                    Text(L("−60 хв", "−60 min")); Spacer(); Text("−30"); Spacer(); Text(L("зараз", "now"))
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.primary.opacity(hover ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("Детальний графік", "Detailed chart"))
    }
}

// MARK: - Tiles

private struct Tiles: View {
    let st: Station
    let open: (Metric) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(tiles, id: \.title) { t in TileView(tile: t) { open(t.metric) } }
        }
    }

    /// " · КПД 90%" for the current load once the loss model has learned something.
    private var efficiencyNote: String {
        guard st.loss.isLearned, let load = st.smoothedLoad, load >= 10,
              let draw = st.batteryDraw, draw > 0 else { return "" }
        return L("ККД \(Int((min(1, load / draw) * 100).rounded()))%", "eff. \(Int((min(1, load / draw) * 100).rounded()))%")
    }

    private var tiles: [Tile] {
        var out: [Tile] = []
        let gi = st.v("gridInPw") ?? st.v("inOngridPw"), go = st.v("gridOutPw") ?? st.v("outOngridPw")
        if gi != nil || go != nil {
            let net = (gi ?? 0) - (go ?? 0)
            out.append(Tile(metric: .grid, title: L("Мережа", "Grid"), icon: "bolt.horizontal.fill", value: Fmt.watts(abs(net)),
                            caption: net > 5 ? L("з мережі", "importing") : net < -5 ? L("у мережу", "exporting") : L("простій", "idle"),
                            tint: net > 5 ? .blue : net < -5 ? Palette.green : .secondary))
        }
        let epsIn = st.v("swEpsInPw") ?? 0, epsOut = st.v("swEpsOutPw") ?? 0
        if st.v("swEpsInPw") != nil || st.v("swEpsOutPw") != nil {
            out.append(Tile(metric: .ac, title: L("Розетка AC", "AC outlet"), icon: "poweroutlet.type.f.fill", value: Fmt.watts(epsIn > 0 ? epsIn : epsOut),
                            caption: epsIn > 0 ? L("вхід", "input") : L("навантаження", "load"), tint: .purple))
        }
        if st.pvSeen {
            out.append(Tile(metric: .pv, title: L("Сонце", "Solar"), icon: "sun.max.fill", value: Fmt.watts(st.v("pvPw")), caption: L("генерація", "generation"), tint: Palette.amber))
        }
        if let net = st.smoothedNet {
            out.append(Tile(metric: .battery, title: L("Батарея", "Battery"), icon: net >= 15 ? "battery.100percent.bolt" : "battery.75percent",
                            value: Fmt.watts(abs(net)),
                            caption: net <= -15 && !efficiencyNote.isEmpty ? efficiencyNote
                                : (net >= 15 ? L("заряд", "charging") : net <= -15 ? L("розряд", "discharging") : L("простій", "idle")),
                            tint: net >= 15 ? Palette.green : net <= -15 ? Palette.discharge : .secondary))
        }
        if let wh = st.usableWh {
            out.append(Tile(metric: .energy, title: L("Доступно", "Available"), icon: "gauge.with.dots.needle.67percent",
                            value: String(format: "%.2f", wh / 1000) + L(" кВт·год", " kWh"),
                            caption: String(format: L("з %.2f", "of %.2f"), st.capacityWh / 1000), tint: .teal))
        }
        if let t = st.cellTempC {
            let lo = st.v("minCellTemp").map { $0 > 100 ? $0 / 10 : $0 }
            let hi = st.v("maxCellTemp").map { $0 > 100 ? $0 / 10 : $0 }
            let range = (lo != nil && hi != nil) ? String(format: "%.0f–%.0f °C", lo!, hi!) : L("комірки", "cells")
            out.append(Tile(metric: .temp, title: L("Температура", "Temperature"), icon: "thermometer.medium", value: String(format: "%.1f °C", t),
                            caption: range, tint: t > 40 ? Palette.red : .pink))
        }
        if out.count % 3 != 0, let sig = st.v("wsig"), sig < 0 {
            let q = sig >= -55 ? L("відмінний", "excellent") : sig >= -67 ? L("добрий", "good") : sig >= -75 ? L("слабкий", "weak") : L("поганий", "poor")
            out.append(Tile(metric: .wifi, title: "Wi‑Fi", icon: "wifi", value: "\(Int(sig)) dBm", caption: q,
                            tint: sig >= -67 ? .blue : Palette.amber))
        }
        return out
    }
}

private struct Tile {
    let metric: Metric
    let title: String
    let icon: String
    let value: String
    let caption: String
    let tint: Color
}

private struct TileView: View {
    let tile: Tile
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) { content }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(L("Графік: \(tile.title)", "Chart: \(tile.title)"))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: tile.icon).font(.system(size: 10)).foregroundStyle(tile.tint)
                Text(tile.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(tile.value)
                .font(.system(size: 15, weight: .regular)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(tile.caption).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(hover ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Unconfigured / footer

private struct Unconfigured: View {
    let open: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.batteryblock").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(L("Станцію не налаштовано", "Station isn’t set up")).font(.system(size: 14, weight: .semibold))
            Text(L("Вкажи брокер, серійний номер і токен станції", "Enter the broker, serial number and token"))
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(L("Відкрити налаштування", "Open settings"), action: open).controlSize(.regular)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
    }
}

private struct Footer: View {
    let st: Station?
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 6) {
                if let st {
                    Text(L("Розряд до \(Int(st.minSoc))% · заряд до \(Int(st.maxSoc))% · \(Fmt.ago(st.lastUpdate))", "Discharge to \(Int(st.minSoc))% · charge to \(Int(st.maxSoc))% · \(Fmt.ago(st.lastUpdate))"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 4) {
                LanguagePicker(current: Lang.current) { model.onLanguage($0) }
                Spacer()
                IconButton(symbol: "gearshape", help: L("Налаштування", "Settings"), action: model.openSettings)
                IconButton(symbol: "arrow.clockwise", help: L("Перепідключитися", "Reconnect"), action: model.onReload)
                IconButton(symbol: "power", help: L("Вийти", "Quit")) { NSApp.terminate(nil) }
            }
        }
    }

}

/// Compact "УКР | EN" switch in the footer; applies immediately.
private struct LanguagePicker: View {
    let current: Lang
    let select: (Lang) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Lang.allCases, id: \.rawValue) { lang in
                Button { select(lang) } label: {
                    Text(lang == .uk ? "УКР" : "EN")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(current == lang ? Color.primary.opacity(0.16) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(current == lang ? .primary : .secondary)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .help(L("Мова", "Language"))
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 26, height: 22)
                .background(Color.primary.opacity(hover ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hover = $0 }
    }
}

// MARK: - Popup window (replaces NSPopover, which mis-sizes self-resizing SwiftUI content)

final class PopupWindow<Content: View> {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let window: Panel
    private let hosting: NSHostingView<Content>
    private weak var anchor: NSStatusBarButton?
    private var monitors: [Any] = []
    private let gap: CGFloat = 6
    private let margin: CGFloat = 8

    var isVisible: Bool { window.isVisible }
    /// Called on Escape; return true if handled (popup stays open).
    var onEscape: () -> Bool = { false }
    private let blur = NSVisualEffectView()
    private let tint = NSView()

    /// "dark" (default), "light" or "system".
    var theme: String = "dark" { didSet { applyTheme() } }

    private func applyTheme() {
        switch theme {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "system": window.appearance = nil
        default: window.appearance = NSAppearance(named: .darkAqua)
        }
        // Dark theme: deeper, almost black glass instead of the grey popover material.
        let dark = theme != "light" && (theme != "system" || NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        blur.material = dark ? .hudWindow : .popover
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.45 : 0).cgColor
    }

    init(root: Content) {
        hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // The window size is managed by fitToContent(); don't let SwiftUI resize it on its own.
        hosting.sizingOptions = []

        window = Panel(contentRect: NSRect(x: 0, y: 0, width: 344, height: 400),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.cgColor
        tint.wantsLayer = true
        tint.frame = blur.bounds
        tint.autoresizingMask = [.width, .height]
        blur.addSubview(tint)
        blur.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: blur.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        window.contentView = blur
        applyTheme()
    }

    /// Horizontal position is fixed while the popup is open: the status item's width changes
    /// with its text, and re-centring on every update makes the window jitter.
    private var pinnedX: CGFloat?

    func show(below button: NSStatusBarButton) {
        anchor = button
        pinnedX = nil
        fitToContent()
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }

        // Close on any click outside the window, on Escape, or when another app takes focus.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 {
                if self?.onEscape() != true { self?.close() }
                return nil
            }
            return e
        } as Any)
    }

    func close() {
        guard window.isVisible else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        window.orderOut(nil)
    }

    /// Sizes the window to the SwiftUI content and pins it right under the status item,
    /// clamped to the visible area of that screen.
    func fitToContent() {
        guard let button = anchor, let bw = button.window else { return }
        // Measure the SwiftUI content itself; the hosting view's fittingSize just echoes the window size.
        let measured = NSHostingController(rootView: hosting.rootView)
            .sizeThatFits(in: NSSize(width: 344, height: 4000))
        let size = NSSize(width: 344, height: ceil(measured.height))
        let anchorRect = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bw.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var x = pinnedX ?? (anchorRect.midX - size.width / 2)
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        pinnedX = x
        let top = min(anchorRect.minY - gap, visible.maxY - gap)
        let height = min(size.height, top - visible.minY - margin)
        let frame = NSRect(x: x, y: top - height, width: size.width, height: height)
        if window.frame != frame { window.setFrame(frame, display: true) }
        if CommandLine.arguments.contains("--debug") {
            FileHandle.standardError.write("[popup] anchor=\(anchorRect) visible=\(visible) content=\(size) frame=\(frame)\n".data(using: .utf8)!)
        }
    }
}
