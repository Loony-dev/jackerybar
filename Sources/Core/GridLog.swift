// Mains presence: outage detection with debouncing, the outage log (JSON) and per-outage statistics.

import Foundation

final class GridLog {
    struct Outage: Codable {
        var start: Double
        var end: Double?
        /// Start is only known approximately (the app was started during the outage).
        var approx: Bool?
        /// One-minute data captured while the 24 h history still covered this outage.
        var series: OutageSeries?
        var duration: Double { (end ?? Date().timeIntervalSince1970) - start }
    }

    func setSeries(_ s: OutageSeries, forStart start: Double) {
        if let i = outages.firstIndex(where: { $0.start == start }) { outages[i].series = s }
    }

    func outage(start: Double) -> Outage? { outages.first { $0.start == start } }

    private(set) var outages: [Outage] = []
    /// Debounced state: nil until known.
    private(set) var isOn: Bool?
    /// When the current state began, if known.
    private(set) var since: Double?
    /// When outage tracking started (before that nothing is known).
    private(set) var trackingSince: Double?

    /// Fired on a real change (not on the first reading after start): (isOn, the outage that just ended).
    var onChange: ((Bool, Outage?) -> Void)?

    private var candidate: Bool?
    private var candidateCount = 0
    private var candidateSince = 0.0
    static let keepDays = 90.0

    /// Feed every reading; the state flips after 2 agreeing readings (~10 s) to ignore blips.
    func update(_ present: Bool?, at t: Double = Date().timeIntervalSince1970) {
        guard let present else { return }
        if trackingSince == nil { trackingSince = t }
        if present == isOn { candidate = nil; return }
        if candidate != present { candidate = present; candidateCount = 0; candidateSince = t }
        candidateCount += 1
        guard candidateCount >= 2 else { return }
        let first = isOn == nil
        let when = candidateSince
        isOn = present
        candidate = nil

        if present {
            if let i = outages.indices.last, outages[i].end == nil {
                outages[i].end = when
                since = when
                if !first { onChange?(true, outages[i]) }
            } else {
                since = first ? outages.last?.end : when
                if !first { onChange?(true, nil) }
            }
        } else {
            if let last = outages.last, last.end == nil {
                since = last.start          // app restarted during an outage it already knew about
            } else {
                outages.append(Outage(start: when, end: nil, approx: first ? true : nil))
                since = when
                if !first { onChange?(false, nil) }
            }
        }
        trim()
    }

    private func trim() {
        let cutoff = Date().timeIntervalSince1970 - Self.keepDays * 86400
        outages.removeAll { ($0.end ?? .infinity) < cutoff }
    }

    /// Outages overlapping [from, to], clipped to it.
    func outages(from: Double, to: Double) -> [(start: Double, end: Double)] {
        let now = Date().timeIntervalSince1970
        return outages.compactMap { o in
            let s = max(o.start, from), e = min(o.end ?? now, to)
            return e > s ? (s, e) : nil
        }
    }

    func summary(from: Double, to: Double) -> (count: Int, total: Double, longest: Double) {
        let parts = outages(from: from, to: to)
        let total = parts.reduce(0) { $0 + ($1.end - $1.start) }
        return (parts.count, total, parts.map { $0.end - $0.start }.max() ?? 0)
    }

    // --- persistence

    private struct File: Codable { var v: Int; var trackingSince: Double?; var outages: [Outage] }

    func save(to url: URL) {
        guard let d = try? JSONEncoder().encode(File(v: 1, trackingSince: trackingSince, outages: outages)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// Forgets every outage (used by "clear all data"). The current state is kept.
    func removeAll() {
        outages.removeAll()
        trackingSince = isOn == nil ? nil : Date().timeIntervalSince1970
        since = nil
    }

    func load(from url: URL) {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return }
        outages = f.outages.sorted { $0.start < $1.start }
        trackingSince = f.trackingSince ?? outages.first?.start
        trim()
    }
}

/// One-minute series captured for an outage, stored inside the outage log so stats survive
/// after the 24 h metric history has rolled over.
struct OutageSeries: Codable {
    var t0: Double
    var step: Double
    var ac: [Double?]
    var bat: [Double?]
    var soc: [Double?]
    var temp: [Double?]

    var count: Int { ac.count }
}

struct OutageStats {
    var duration: Double
    var consumedKWh: Double        // delivered to the AC socket
    var usedKWh: Double            // taken out of the battery
    var chargedKWh: Double         // put into the battery (e.g. solar) during the outage
    var loadMin: Double?, loadAvg: Double?, loadMax: Double?
    var dischargeMax: Double?, dischargeAvg: Double?
    var socStart: Double?, socEnd: Double?, socMin: Double?
    var tempMin: Double?, tempMax: Double?
    var coverage: Double           // share of minutes with data

    var socDrop: Double? { socStart.flatMap { s in socEnd.map { s - $0 } } }
    var efficiency: Double? { usedKWh > 0.01 ? min(1, consumedKWh / usedKWh) : nil }
    var socPerHour: Double? {
        guard let d = socDrop, duration > 600 else { return nil }
        return d / (duration / 3600)
    }
}

extension OutageSeries {
    func stats(duration: Double) -> OutageStats {
        let h = step / 3600
        func vals(_ a: [Double?]) -> [Double] { a.compactMap { $0 } }
        let ac = vals(self.ac), bat = vals(self.bat), soc = vals(self.soc), temp = vals(self.temp)
        let discharge = bat.filter { $0 < -5 }.map { -$0 }
        let socFirst = self.soc.first(where: { $0 != nil }) ?? nil
        let socLast = self.soc.last(where: { $0 != nil }) ?? nil
        return OutageStats(
            duration: duration,
            consumedKWh: ac.reduce(0) { $0 + max(0, $1) * h } / 1000,
            usedKWh: bat.reduce(0) { $0 + max(0, -$1) * h } / 1000,
            chargedKWh: bat.reduce(0) { $0 + max(0, $1) * h } / 1000,
            loadMin: ac.min(), loadAvg: ac.isEmpty ? nil : ac.reduce(0, +) / Double(ac.count), loadMax: ac.max(),
            dischargeMax: discharge.max(),
            dischargeAvg: discharge.isEmpty ? nil : discharge.reduce(0, +) / Double(discharge.count),
            socStart: socFirst, socEnd: socLast, socMin: soc.min(),
            tempMin: temp.min(), tempMax: temp.max(),
            coverage: count == 0 ? 0 : Double(self.ac.filter { $0 != nil }.count) / Double(count)
        )
    }
}

/// Averages a series down to at most `max` points (for drawing).
func downsample(_ a: [Double?], to max: Int) -> [Double?] {
    guard a.count > max, max > 0 else { return a }
    return (0..<max).map { i in
        let lo = i * a.count / max, hi = (i + 1) * a.count / max
        let v = a[lo..<hi].compactMap { $0 }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
}
