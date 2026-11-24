// Per-metric history (persisted as JSON) and the detail page with a chart for each metric.

import SwiftUI

// MARK: - Metrics

enum Metric: String, CaseIterable {
    case battery, grid, ac, pv, soc, energy, temp, wifi

    var title: String {
        switch self {
        case .battery: L("Батарея", "Battery")
        case .grid: L("Мережа", "Grid")
        case .ac: L("Розетка AC", "AC outlet")
        case .pv: L("Сонце", "Solar")
        case .soc: L("Заряд", "Charge")
        case .energy: L("Доступно", "Available")
        case .temp: L("Температура", "Temperature")
        case .wifi: "Wi‑Fi"
        }
    }

    var icon: String {
        switch self {
        case .battery: "battery.75percent"
        case .grid: "bolt.horizontal.fill"
        case .ac: "poweroutlet.type.f.fill"
        case .pv: "sun.max.fill"
        case .soc: "battery.100percent"
        case .energy: "gauge.with.dots.needle.67percent"
        case .temp: "thermometer.medium"
        case .wifi: "wifi"
        }
    }

    /// Main colour; for signed metrics this is the colour above zero.
    var tint: Color {
        switch self {
        case .battery: Palette.green
        case .grid: .blue
        case .ac: .purple
        case .pv: Palette.amber
        case .soc: Palette.green
        case .energy: .teal
        case .temp: .pink
        case .wifi: .blue
        }
    }

    /// Colour below zero for signed metrics.
    var negativeTint: Color { self == .grid ? Palette.green : Palette.discharge }

    /// Stored column ("Доступно" is derived from the SOC column).
    var column: String { self == .energy ? "soc" : rawValue }
    var isPower: Bool { [.battery, .grid, .ac, .pv].contains(self) }
    /// Power that flows both ways: drawn in two colours around the zero line.
    var isSigned: Bool { self == .battery || self == .grid }

    func format(_ v: Double) -> String {
        switch self {
        case .battery, .grid: (v > 0.5 ? "+" : v < -0.5 ? "−" : "") + Fmt.watts(abs(v))
        case .ac, .pv: Fmt.watts(v)
        case .soc: "\(Int(v.rounded()))%"
        case .energy: String(format: L("%.2f кВт·год", "%.2f kWh"), v)
        case .temp: String(format: "%.1f °C", v)
        case .wifi: "\(Int(v.rounded())) dBm"
        }
    }

    /// Compact form for axis labels.
    func axis(_ v: Double) -> String {
        switch self {
        case .battery, .grid, .ac, .pv: abs(v) >= 1000 ? String(format: L("%.1fк", "%.1fk"), v / 1000) : "\(Int(v.rounded()))"
        case .soc: "\(Int(v.rounded()))%"
        case .energy: String(format: "%.1f", v)
        case .temp: String(format: "%.0f°", v)
        case .wifi: "\(Int(v.rounded()))"
        }
    }

    /// Words for the energy integrals of power metrics: (above zero, below zero).
    var energyLabels: (String, String)? {
        switch self {
        case .battery: (L("Заряджено", "Charged"), L("Віддано", "Discharged"))
        case .grid: (L("З мережі", "Imported"), L("У мережу", "Exported"))
        case .ac: (L("Спожито", "Consumed"), "")
        case .pv: (L("Вироблено", "Generated"), "")
        default: nil
        }
    }
}

extension Station {
    /// Net grid-port power, + from grid / − to grid.
    var gridNet: Double? {
        let gi = v("gridInPw") ?? v("inOngridPw"), go = v("gridOutPw") ?? v("outOngridPw")
        guard gi != nil || go != nil else { return nil }
        return (gi ?? 0) - (go ?? 0)
    }

    /// Raw values recorded into the history store.
    func metricValues() -> [String: Double] {
        var d: [String: Double] = [:]
        if let n = rawNet { d["battery"] = n }
        if let g = gridNet { d["grid"] = g }
        if v("swEpsOutPw") != nil || v("swEpsInPw") != nil { d["ac"] = v("swEpsOutPw") ?? 0 }
        if let p = v("pvPw") { d["pv"] = p }
        if let s = soc { d["soc"] = s }
        if let t = cellTempC { d["temp"] = t }
        if let w = v("wsig"), w < 0 { d["wifi"] = w }
        return d
    }

    /// Current value shown on the detail page.
    func current(_ m: Metric) -> Double? {
        switch m {
        case .battery: smoothedNet
        case .grid: gridNet
        case .ac: v("swEpsOutPw")
        case .pv: v("pvPw")
        case .soc: soc
        case .energy: usableWh.map { $0 / 1000 }
        case .temp: cellTempC
        case .wifi: v("wsig")
        }
    }

    /// Maps a stored value to what the metric shows (only "Доступно" needs it: SOC → kWh).
    func transform(for m: Metric) -> (Double) -> Double {
        guard m == .energy else { return { $0 } }
        let lo = minSoc, cap = capacityWh
        return { max(0, $0 - lo) / 100 * cap / 1000 }
    }
}

// MARK: - Store

/// All metrics in one table: a row every ≥10 s, kept for 24 h, saved as
/// {"v":1,"cols":["t","battery",…],"rows":[[unixTime, value|null, …], …]}.
final class MetricStore {
    static let columns = ["battery", "grid", "ac", "pv", "soc", "temp", "wifi"]
    static let retention: TimeInterval = 24 * 3600
    static let step: TimeInterval = 10

    private(set) var times: [Double] = []
    private var data: [String: [Double?]] = Dictionary(uniqueKeysWithValues: MetricStore.columns.map { ($0, []) })

    var count: Int { times.count }
    var firstTime: Double? { times.first }

    func record(at date: Date, values: [String: Double]) {
        let t = date.timeIntervalSince1970
        if let last = times.last, t < last { return }
        let n = times.count
        if n >= 2, t - times[n - 2] < Self.step {
            // Keep rows ≥ step apart but the newest row always fresh.
            times[n - 1] = t
            for c in Self.columns { data[c]![n - 1] = values[c] }
        } else {
            times.append(t)
            for c in Self.columns { data[c]!.append(values[c]) }
        }
        trim(now: t)
    }

    private func trim(now: Double) {
        let cutoff = now - Self.retention
        guard let first = times.first, first < cutoff,
              let i = times.firstIndex(where: { $0 >= cutoff }) else { return }
        times.removeFirst(i)
        for c in Self.columns { data[c]!.removeFirst(i) }
    }

    private func lowerBound(_ t: Double) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Averages of `metric` in `count` equal time buckets over [from, to]; nil where there is no data.
    func buckets(_ m: Metric, from: Double, to: Double, count: Int, transform: (Double) -> Double) -> [Double?] {
        guard to > from, count > 0, let col = data[m.column] else { return [] }
        var sums = [Double](repeating: 0, count: count), ns = [Int](repeating: 0, count: count)
        var i = lowerBound(from)
        while i < times.count, times[i] <= to {
            if let v = col[i] {
                let b = min(count - 1, Int((times[i] - from) / (to - from) * Double(count)))
                sums[b] += transform(v)
                ns[b] += 1
            }
            i += 1
        }
        return (0..<count).map { ns[$0] > 0 ? sums[$0] / Double(ns[$0]) : nil }
    }

    struct Stats { var min: Double; var max: Double; var avg: Double; var posKWh: Double; var negKWh: Double; var since: Double }

    /// Min/avg/max over the range; for power metrics also energy (kWh) above/below zero.
    func stats(_ m: Metric, from: Double, to: Double, transform: (Double) -> Double) -> Stats? {
        guard let col = data[m.column] else { return nil }
        var lo = Double.infinity, hi = -Double.infinity, sum = 0.0, n = 0
        var pos = 0.0, neg = 0.0, since: Double?
        var prev: (t: Double, v: Double)?
        var i = lowerBound(from)
        while i < times.count, times[i] <= to {
            if let raw = col[i] {
                let v = transform(raw)
                lo = min(lo, v); hi = max(hi, v); sum += v; n += 1
                if since == nil { since = times[i] }
                if let p = prev {
                    let dt = times[i] - p.t
                    if dt <= 60 {                       // don't integrate across gaps
                        let wh = (p.v + v) / 2 * dt / 3600
                        if wh > 0 { pos += wh } else { neg -= wh }
                    }
                }
                prev = (times[i], v)
            }
            i += 1
        }
        guard n > 0, let since else { return nil }
        return Stats(min: lo, max: hi, avg: sum / Double(n), posKWh: pos / 1000, negKWh: neg / 1000, since: since)
    }

    // --- persistence

    private struct File: Codable {
        var v: Int
        var cols: [String]
        var rows: [[Double?]]
    }

    func save(to url: URL) {
        let rows: [[Double?]] = times.indices.map { i in
            [times[i].rounded()] + Self.columns.map { c in data[c]![i].map { ($0 * 10).rounded() / 10 } }
        }
        guard let d = try? JSONEncoder().encode(File(v: 1, cols: ["t"] + Self.columns, rows: rows)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// Loads saved rows (newer than the retention window). Returns false if there was no file.
    @discardableResult
    func load(from url: URL) -> Bool {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return false }
        let idx = Dictionary(uniqueKeysWithValues: f.cols.enumerated().map { ($1, $0) })
        guard let ti = idx["t"] else { return false }
        let cutoff = Date().timeIntervalSince1970 - Self.retention
        for row in f.rows {
            guard ti < row.count, let t = row[ti], t >= cutoff else { continue }
            var values: [String: Double] = [:]
            for c in Self.columns { if let j = idx[c], j < row.count, let v = row[j] { values[c] = v } }
            append(t, values)
        }
        return true
    }

    /// Imports the old battery-only history file ([[t, watts], …]).
    func importLegacy(from url: URL) {
        guard let d = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([[Double]].self, from: d) else { return }
        for r in rows where r.count == 2 { append(r[0], ["battery": r[1]]) }
    }

    private func append(_ t: Double, _ values: [String: Double]) {
        if let last = times.last, t <= last { return }
        times.append(t)
        for c in Self.columns { data[c]!.append(values[c]) }
    }
}

// MARK: - Chart

struct SeriesChart: View {
    let points: [Double?]
    let metric: Metric
    let domain: ClosedRange<Double>
    var interactive = false
    var from: Double = 0
    var to: Double = 0

    @State private var hover: Int?

    /// Value range for a series: fixed for SOC/energy, includes zero for power, padded otherwise.
    static func domain(for m: Metric, points: [Double?], capacityKWh: Double) -> ClosedRange<Double> {
        let vals = points.compactMap { $0 }
        switch m {
        case .soc: return 0...100
        case .energy: return 0...max(0.1, capacityKWh)
        default: break
        }
        guard let lo = vals.min(), let hi = vals.max() else { return m.isPower ? -100...100 : 0...1 }
        if m.isPower {
            var a = min(0, lo) * 1.15, b = max(0, hi) * 1.15
            if b - a < 100 { if m.isSigned { a = min(a, -50); b = max(b, 50) } else { b = max(b, 100) } }
            return a...b
        }
        let pad = max(1, (hi - lo) * 0.25)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size) }
                if interactive, let h = hover, h < points.count {
                    overlay(index: h, size: size)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard interactive, !points.isEmpty else { return }
                switch phase {
                case .active(let p):
                    let i = Int(p.x / max(1, size.width) * CGFloat(points.count))
                    hover = min(max(i, 0), points.count - 1)
                case .ended:
                    hover = nil
                }
            }
        }
    }

    private func y(_ v: Double, _ h: CGFloat) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        return h - CGFloat((v - domain.lowerBound) / (span == 0 ? 1 : span)) * h
    }

    private func x(_ i: Int, _ w: CGFloat) -> CGFloat {
        (CGFloat(i) + 0.5) / CGFloat(max(points.count, 1)) * w
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let base = metric.isPower ? 0 : domain.lowerBound
        let baseY = y(min(max(base, domain.lowerBound), domain.upperBound), size.height)

        // Runs of consecutive buckets with data; empty buckets break the line.
        var line = Path(), area = Path()
        var run: [CGPoint] = []
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            var l = Path()
            l.move(to: first)
            if run.count == 1 { l.addLine(to: CGPoint(x: first.x + 1.5, y: first.y)) }
            for p in run.dropFirst() { l.addLine(to: p) }
            var a = l
            a.addLine(to: CGPoint(x: run.count == 1 ? first.x + 1.5 : last.x, y: baseY))
            a.addLine(to: CGPoint(x: first.x, y: baseY))
            a.closeSubpath()
            line.addPath(l); area.addPath(a)
            run.removeAll()
        }
        for (i, v) in points.enumerated() {
            if let v { run.append(CGPoint(x: x(i, size.width), y: y(v, size.height))) } else { flush() }
        }
        flush()

        if metric.isSigned {
            ctx.drawLayer { c in
                c.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: baseY)))
                c.fill(area, with: .linearGradient(Gradient(colors: [metric.tint.opacity(0.45), metric.tint.opacity(0.05)]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: baseY)))
                c.stroke(line, with: .color(metric.tint), lineWidth: 1.5)
            }
            ctx.drawLayer { c in
                c.clip(to: Path(CGRect(x: 0, y: baseY, width: size.width, height: size.height - baseY)))
                c.fill(area, with: .linearGradient(Gradient(colors: [metric.negativeTint.opacity(0.05), metric.negativeTint.opacity(0.45)]),
                                                   startPoint: CGPoint(x: 0, y: baseY), endPoint: CGPoint(x: 0, y: size.height)))
                c.stroke(line, with: .color(metric.negativeTint), lineWidth: 1.5)
            }
        } else {
            ctx.fill(area, with: .linearGradient(Gradient(colors: [metric.tint.opacity(0.4), metric.tint.opacity(0.03)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(metric.tint), lineWidth: 1.5)
        }

        if metric.isPower {
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: baseY))
            zero.addLine(to: CGPoint(x: size.width, y: baseY))
            ctx.stroke(zero, with: .color(.primary.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    @ViewBuilder
    private func overlay(index h: Int, size: CGSize) -> some View {
        let px = x(h, size.width)
        let t = from + (Double(h) + 0.5) / Double(points.count) * (to - from)
        Path { p in
            p.move(to: CGPoint(x: px, y: 0))
            p.addLine(to: CGPoint(x: px, y: size.height))
        }
        .stroke(Color.primary.opacity(0.3), lineWidth: 1)
        if let v = points[h] {
            let color = metric.isSigned && v < 0 ? metric.negativeTint : metric.tint
            Circle().fill(color).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                .position(x: px, y: y(v, size.height))
        }
        let label = "\(Fmt.clock(t)) · " + (points[h].map(metric.format) ?? L("немає даних", "no data"))
        Text(label)
            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
            .position(x: min(max(px, 62), size.width - 62), y: -12)
    }
}

extension Fmt {
    static func clock(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

// MARK: - Detail page

struct DetailView: View {
    @ObservedObject var model: PanelModel
    let st: Station
    let metric: Metric

    private let ranges: [(String, TimeInterval)] = [(L("1 год", "1 h"), 3600), (L("6 год", "6 h"), 6 * 3600), (L("24 год", "24 h"), 24 * 3600)]

    var body: some View {
        let _ = model.tick
        let now = Date().timeIntervalSince1970
        let from = now - model.detailRange
        let tf = st.transform(for: metric)
        let pts = st.store.buckets(metric, from: from, to: now, count: 156, transform: tf)
        let dom = SeriesChart.domain(for: metric, points: pts, capacityKWh: st.capacityWh / 1000)
        let stats = st.store.stats(metric, from: from, to: now, transform: tf)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button { model.detail = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(L("Назад", "Back"))
                Image(systemName: metric.icon).foregroundStyle(metric.tint)
                Text(metric.title).font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            HStack(alignment: .firstTextBaseline) {
                Text(st.current(metric).map(metric.format) ?? "—")
                    .font(.system(size: 34, weight: .light)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer()
                RangePicker(ranges: ranges, selection: $model.detailRange)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    AxisLabels(metric: metric, domain: dom)
                        .frame(width: 30, height: 150)

                    ZStack {
                        if pts.allSatisfy({ $0 == nil }) {
                            Text(L("немає даних за цей період", "no data for this period")).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        SeriesChart(points: pts, metric: metric, domain: dom, interactive: true, from: from, to: now)
                    }
                    .frame(height: 150)
                }
                HStack {
                    Text(Fmt.clock(from)); Spacer(); Text(Fmt.clock(from + (now - from) / 2)); Spacer(); Text(L("зараз", "now"))
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .padding(.leading, 36)
            }
            .padding(.top, 14)
            .padding([.horizontal, .bottom], 12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let s = stats {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    StatCell(title: L("Мін", "Min"), value: metric.format(s.min))
                    StatCell(title: L("Середнє", "Average"), value: metric.format(s.avg))
                    StatCell(title: L("Макс", "Max"), value: metric.format(s.max))
                    if let (posLabel, negLabel) = metric.energyLabels {
                        StatCell(title: posLabel, value: String(format: L("%.2f кВт·год", "%.2f kWh"), s.posKWh))
                        if !negLabel.isEmpty {
                            StatCell(title: negLabel, value: String(format: L("%.2f кВт·год", "%.2f kWh"), s.negKWh))
                        }
                    }
                }
                if s.since > from + 120 {
                    Text(L("Дані є з \(Fmt.clock(s.since))", "Data since \(Fmt.clock(s.since))"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Y-axis labels placed on the same scale as the chart (top, zero for power, bottom).
private struct AxisLabels: View {
    let metric: Metric
    let domain: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = max(domain.upperBound - domain.lowerBound, 1e-9)
            let y = { (v: Double) -> CGFloat in h - CGFloat((v - domain.lowerBound) / span) * h }
            let zeroY = y(0)
            ZStack(alignment: .topTrailing) {
                label(domain.upperBound, at: 5)
                label(domain.lowerBound, at: h - 5)
                if metric.isPower, domain.lowerBound < 0, domain.upperBound > 0, zeroY > 16, zeroY < h - 16 {
                    label(0, at: zeroY)
                }
            }
            .frame(width: geo.size.width, height: h, alignment: .topTrailing)
        }
        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.tertiary)
    }

    private func label(_ v: Double, at y: CGFloat) -> some View {
        Text(metric.axis(v)).fixedSize()
            .frame(width: 30, alignment: .trailing)
            .position(x: 15, y: y)
    }
}

private struct RangePicker: View {
    let ranges: [(String, TimeInterval)]
    @Binding var selection: TimeInterval

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ranges, id: \.1) { r in
                Button { selection = r.1 } label: {
                    Text(r.0)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(selection == r.1 ? Color.primary.opacity(0.16) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == r.1 ? .primary : .secondary)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

private struct StatCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
