// Metric history: raw points for the last 24 h plus 5-minute averages kept for a year.
// Both are plain JSON tables: {"v":1,"cols":["t","battery",…],"rows":[[unixTime, value|null, …], …]}.

import Foundation

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

    /// SF Symbol name.
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

/// One time-series table with a fixed set of columns.
final class Table {
    static let columns = ["battery", "grid", "ac", "pv", "soc", "temp", "wifi"]

    /// Minimum spacing of rows (the newest row is overwritten until it's this old).
    let step: TimeInterval
    let retention: TimeInterval
    /// Rows further apart than this are a gap: not integrated, not joined by a line.
    let maxGap: TimeInterval

    private(set) var times: [Double] = []
    private var data: [String: [Double?]] = Dictionary(uniqueKeysWithValues: Table.columns.map { ($0, []) })

    init(step: TimeInterval, retention: TimeInterval, maxGap: TimeInterval) {
        self.step = step; self.retention = retention; self.maxGap = maxGap
    }

    var count: Int { times.count }
    var firstTime: Double? { times.first }
    var lastTime: Double? { times.last }

    func value(_ column: String, at i: Int) -> Double? { data[column]?[i] ?? nil }

    /// Adds a sample; rows stay ≥ `step` apart, but the newest row always holds the freshest values.
    func record(at t: Double, values: [String: Double]) {
        if let last = times.last, t < last { return }
        let n = times.count
        if n >= 2, t - times[n - 2] < step {
            times[n - 1] = t
            for c in Self.columns { data[c]![n - 1] = values[c] }
        } else {
            times.append(t)
            for c in Self.columns { data[c]!.append(values[c]) }
        }
        trim(now: t)
    }

    /// Appends a row as is (strictly increasing time).
    func append(_ t: Double, _ values: [String: Double]) {
        if let last = times.last, t <= last { return }
        times.append(t)
        for c in Self.columns { data[c]!.append(values[c]) }
    }

    func trim(now: Double) {
        let cutoff = now - retention
        guard let first = times.first, first < cutoff, let i = times.firstIndex(where: { $0 >= cutoff }) else {
            if let last = times.last, last < cutoff { removeAll() }
            return
        }
        times.removeFirst(i)
        for c in Self.columns { data[c]!.removeFirst(i) }
    }

    func removeAll() {
        times.removeAll()
        for c in Self.columns { data[c]!.removeAll() }
    }

    func lowerBound(_ t: Double) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Averages of `column` in `count` equal time buckets over [from, to]; nil where there is no data.
    func buckets(_ column: String, from: Double, to: Double, count: Int, transform: (Double) -> Double) -> [Double?] {
        guard to > from, count > 0, let col = data[column] else { return [] }
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

    /// Min/avg/max over the range; for power columns also energy (kWh) above/below zero.
    func stats(_ column: String, from: Double, to: Double, transform: (Double) -> Double) -> Stats? {
        guard let col = data[column] else { return nil }
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
                    if dt <= maxGap {                         // don't integrate across gaps
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

    /// Loads saved rows newer than the retention window. Returns false if there was no file.
    @discardableResult
    func load(from url: URL, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return false }
        let idx = Dictionary(uniqueKeysWithValues: f.cols.enumerated().map { ($1, $0) })
        guard let ti = idx["t"] else { return false }
        let cutoff = now - retention
        for row in f.rows {
            guard ti < row.count, let t = row[ti], t >= cutoff else { continue }
            var values: [String: Double] = [:]
            for c in Self.columns { if let j = idx[c], j < row.count, let v = row[j] { values[c] = v } }
            append(t, values)
        }
        return true
    }
}

/// Per-day energy totals (kWh), computed from the long-term table.
struct DayEnergy: Equatable {
    var dayStart: Double
    var consumed = 0.0      // AC outlet
    var discharged = 0.0    // out of the battery
    var charged = 0.0       // into the battery
    var imported = 0.0      // from the grid
    var exported = 0.0      // to the grid
    var solar = 0.0
    /// Cost of what was taken from the grid, in the tariff's currency.
    var cost = 0.0
    var hasData = false
}

final class MetricStore {
    static let rawRetention: TimeInterval = 24 * 3600
    static let longStep: TimeInterval = 300
    static let longRetention: TimeInterval = 365 * 86400

    /// Every ~10 s, last 24 h.
    let raw = Table(step: 10, retention: rawRetention, maxGap: 60)
    /// 5-minute averages, last year.
    let long = Table(step: longStep, retention: longRetention, maxGap: 3 * longStep)

    /// Open 5-minute bucket being averaged.
    private var bucketStart: Double?
    private var sums: [String: Double] = [:]
    private var counts: [String: Int] = [:]
    /// Set when a 5-minute row was added since the last save.
    private(set) var longDirty = false

    func record(at date: Date, values: [String: Double]) {
        let t = date.timeIntervalSince1970
        raw.record(at: t, values: values)
        accumulate(t, values)
    }

    private func accumulate(_ t: Double, _ values: [String: Double]) {
        let start = (t / Self.longStep).rounded(.down) * Self.longStep
        if let b = bucketStart, b != start { flushBucket() }
        if bucketStart == nil { bucketStart = start }
        for (k, v) in values where Table.columns.contains(k) {
            sums[k, default: 0] += v
            counts[k, default: 0] += 1
        }
    }

    private func flushBucket() {
        guard let b = bucketStart else { return }
        var avg: [String: Double] = [:]
        for (k, s) in sums { if let n = counts[k], n > 0 { avg[k] = s / Double(n) } }
        if !avg.isEmpty {
            long.append(b, avg)
            long.trim(now: b)
            longDirty = true
        }
        bucketStart = nil
        sums.removeAll(); counts.removeAll()
    }

    /// Picks the table that covers `from`: raw for the last 24 h, the 5-minute table beyond that.
    func table(from: Double, now: Double = Date().timeIntervalSince1970) -> Table {
        from >= now - Self.rawRetention + 60 ? raw : long
    }

    func buckets(_ m: Metric, from: Double, to: Double, count: Int, transform: (Double) -> Double = { $0 }) -> [Double?] {
        table(from: from).buckets(m.column, from: from, to: to, count: count, transform: transform)
    }

    func stats(_ m: Metric, from: Double, to: Double, transform: (Double) -> Double = { $0 }) -> Table.Stats? {
        table(from: from).stats(m.column, from: from, to: to, transform: transform)
    }

    /// Energy totals for each of the last `days` days (oldest first), today included.
    func daily(days: Int, now: Double = Date().timeIntervalSince1970, calendar: Calendar = .current, tariff: TariffConfig? = nil) -> [DayEnergy] {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        return (0..<days).reversed().map { k in
            let start = calendar.date(byAdding: .day, value: -k, to: today)!.timeIntervalSince1970
            let end = calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: start))!.timeIntervalSince1970
            var d = DayEnergy(dayStart: start)
            let i0 = long.lowerBound(start)
            var i = i0
            let h = Self.longStep / 3600
            while i < long.count, long.times[i] < end {
                d.hasData = true
                if let v = long.value("ac", at: i) { d.consumed += max(0, v) * h / 1000 }
                if let v = long.value("battery", at: i) {
                    if v > 0 { d.charged += v * h / 1000 } else { d.discharged += -v * h / 1000 }
                }
                if let v = long.value("grid", at: i) {
                    if v > 0 {
                        d.imported += v * h / 1000
                        if let tariff { d.cost += v * h / 1000 * tariff.price(atHour: calendar.component(.hour, from: Date(timeIntervalSince1970: long.times[i]))) }
                    } else { d.exported += -v * h / 1000 }
                }
                if let v = long.value("pv", at: i) { d.solar += max(0, v) * h / 1000 }
                i += 1
            }
            return d
        }
    }

    // --- persistence

    func save(raw rawURL: URL, long longURL: URL) {
        raw.save(to: rawURL)
        if longDirty || !FileManager.default.fileExists(atPath: longURL.path) {
            long.save(to: longURL)
            longDirty = false
        }
    }

    func load(raw rawURL: URL, long longURL: URL) {
        raw.load(from: rawURL)
        let hadLong = long.load(from: longURL)
        if !hadLong { backfillLong() }
    }

    /// First run with long-term history: build 5-minute rows from the raw 24 h.
    private func backfillLong() {
        var start: Double?
        var s: [String: Double] = [:], n: [String: Int] = [:]
        func flush() {
            guard let b = start else { return }
            var avg: [String: Double] = [:]
            for (k, v) in s { if let c = n[k], c > 0 { avg[k] = v / Double(c) } }
            if !avg.isEmpty { long.append(b, avg) }
            s.removeAll(); n.removeAll()
        }
        for i in 0..<raw.count {
            let t = raw.times[i]
            let b = (t / Self.longStep).rounded(.down) * Self.longStep
            if start != b { flush(); start = b }
            for c in Table.columns { if let v = raw.value(c, at: i) { s[c, default: 0] += v; n[c, default: 0] += 1 } }
        }
        // The last (still open) bucket keeps accumulating live.
        if let b = start {
            bucketStart = b; sums = s; counts = n
        }
        longDirty = long.count > 0
    }

    func removeAll() {
        raw.removeAll(); long.removeAll()
        bucketStart = nil; sums.removeAll(); counts.removeAll()
        longDirty = false
    }
}
