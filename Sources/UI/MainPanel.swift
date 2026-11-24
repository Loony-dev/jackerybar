// The popup: page router, main page (station switcher, header, hero, power card, chart, tiles, footer).

import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel
    /// Measuring pass: no ScrollView, so the natural height can be read.
    var measuring = false

    var body: some View {
        let _ = model.tick
        if measuring || Snapshot.active {
            content
        } else {
            ScrollView(.vertical) { content }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            page
        }
        .padding(16)
        .frame(width: 344)
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .settings:
            SettingsView(model: model)
        case .metric(let m) where model.station != nil:
            MetricPage(model: model, st: model.station!, metric: m)
        case .outages where model.station != nil:
            OutagesView(model: model, st: model.station!)
        case .outage(let start) where model.station?.grid.outage(start: start) != nil:
            OutageDetailView(model: model, st: model.station!, outage: model.station!.grid.outage(start: start)!)
        case .stats where model.station != nil:
            StatsPage(model: model, st: model.station!)
        case .control where model.station != nil:
            ControlPage(model: model, st: model.station!)
        case .schedule where model.station != nil:
            SchedulePage(model: model, st: model.station!)
        case .queue where model.station != nil:
            QueuePage(model: model, st: model.station!)
        default:
            mainPage
        }
    }

    @ViewBuilder
    private var mainPage: some View {
        if let st = model.station {
            // Station is a mutable class passed by reference: SwiftUI would treat these
            // views as unchanged and never re-render them, so rebuild them on every data tick.
            Group {
                if model.hub.stations.count > 1 {
                    StationSwitcher(stations: model.hub.stations, selected: st.sn) { model.hub.select($0) }
                }
                Header(st: st, error: model.hub.connError, demo: model.hub.isDemo && !Snapshot.active)
                Hero(st: st, open: { model.open(.metric($0)) })
                GridCard(log: st.grid, open: { model.open(.outages) })
                PlanCard(hub: model.hub, st: st, open: { st.config.queue == nil ? model.openQueuePicker() : model.open(.schedule) })
                PowerChart(st: st, open: { model.open(.metric(.battery)) })
                Tiles(st: st, open: { model.open(.metric($0)) })
            }
            .id(model.tick)
        } else {
            Unconfigured(open: model.openSettings)
        }
        Footer(st: model.station, model: model)
    }
}

// MARK: - Station switcher

private struct StationSwitcher: View {
    let stations: [Station]
    let selected: String
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(stations, id: \.sn) { st in
                Button { select(st.sn) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(st.isStale ? Color.secondary : Palette.forSoc(st.soc ?? 0)).frame(width: 6, height: 6)
                        Text(st.name).lineLimit(1)
                        Text(st.soc.map { "\(Int($0.rounded()))%" } ?? "—").foregroundStyle(.secondary).monospacedDigit()
                        if st.grid.isOn == false { Image(systemName: "lightbulb.slash.fill").foregroundStyle(Palette.red) }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(st.sn == selected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(st.sn)
            }
        }
    }
}

// MARK: - Header

private struct Header: View {
    let st: Station
    let error: String?
    let demo: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(st.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(demo ? L("демо-режим", "demo mode") : st.sn)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(state: state, text: stateText)
        }
    }

    private var state: StatusPill.State {
        if error != nil || st.tokenRejected { return .error }
        if st.lastUpdate == nil || st.isStale { return .waiting }
        return .online
    }

    private var stateText: String {
        if error != nil { return L("немає брокера", "no broker") }
        if st.tokenRejected { return L("невірний токен", "wrong token") }
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
        let pts = st.store.buckets(.battery, from: now - 3600, to: now, count: 156)
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
                    Text(L("Розряд до \(Int(st.minSoc))% · заряд до \(Int(st.maxSoc))% · \(Fmt.ago(st.lastUpdate))",
                           "Discharge to \(Int(st.minSoc))% · charge to \(Int(st.maxSoc))% · \(Fmt.ago(st.lastUpdate))"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 2) {
                LanguagePicker(current: Lang.current) { model.onLanguage($0) }
                Spacer()
                if st != nil {
                    IconButton(symbol: "chart.bar.xaxis", help: L("Статистика", "Statistics")) { model.open(.stats) }
                    IconButton(symbol: "slider.horizontal.3", help: L("Керування станцією", "Station control")) { model.open(.control) }
                }
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

