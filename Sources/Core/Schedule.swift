// Planned outage schedules (ГПВ) for Ukrainian regions.
//
// Primary source: Koly Ye (MIT) — normalized JSON on GitHub Pages, updated every 10 min:
//   https://vkardin.github.io/koly/v1/index.json
//   https://vkardin.github.io/koly/v1/regions/<id>.json   (times in Europe/Kyiv)
// Fallback for Khmelnytskyi: frankov-dev/khm_outage_parser (today.json / tomorrow.json).
// Both read the operator's public site (hoe.com.ua for Khmelnytskyi).

import Foundation

/// One planned outage in absolute time.
struct PlannedOutage: Equatable {
    var start: Date
    var end: Date
    /// "maybe" (possible) rather than a definite outage.
    var maybe: Bool

    var duration: TimeInterval { end.timeIntervalSince(start) }
    func contains(_ d: Date) -> Bool { d >= start && d < end }
}

struct RegionInfo: Codable, Equatable {
    struct Name: Codable, Equatable { var uk: String; var en: String; var ru: String? }
    var id: String
    var name: Name
    var provider: String
    var groups: [String]
    var updatedAt: String
    var status: String

    var localizedName: String { Lang.current == .en ? name.en : name.uk }
}

struct RegionIndex: Codable { var schemaVersion: Int?; var generatedAt: String?; var regions: [RegionInfo] }

/// Koly schema v1 region file (plus where we got it from).
struct RegionSchedule: Codable, Equatable {
    struct Interval: Codable, Equatable {
        var from: String
        var to: String
        var type: String
    }
    struct Day: Codable, Equatable {
        var date: String
        var groups: [String: [Interval]]
    }
    struct Emergency: Codable, Equatable {
        var active: Bool = false
        var note: String?
        var since: String?
    }

    var id: String
    var provider: String
    var sourceUrl: String
    var fetchedAt: String
    var updatedAt: String
    var status: String
    var emergency: Emergency?
    var days: [Day]
    /// Which feed produced this copy ("koly" or "frankov").
    var feed: String?

    static let kyiv = TimeZone(identifier: "Europe/Kyiv")!

    static var kyivCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kyiv
        return c
    }

    /// "2026-11-24" + "16:00" (Kyiv) → Date. "24:00" is the next midnight.
    static func date(_ day: String, _ hm: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        let t = hm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 3, t.count == 2 else { return nil }
        var dc = DateComponents(); dc.year = p[0]; dc.month = p[1]; dc.day = p[2]
        guard let midnight = kyivCalendar.date(from: dc) else { return nil }
        return midnight.addingTimeInterval(TimeInterval(t[0] * 3600 + t[1] * 60))
    }

    var groups: [String] {
        Set(days.flatMap { $0.groups.keys }).sorted { Self.groupLess($0, $1) }
    }

    /// "1.2" < "2.1" < "10.1".
    static func groupLess(_ a: String, _ b: String) -> Bool {
        let x = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let y = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return x.lexicographicallyPrecedes(y)
    }

    /// All outages of a group in absolute time, sorted; back-to-back intervals (incl. across midnight) merged.
    func outages(group: String) -> [PlannedOutage] {
        var list: [PlannedOutage] = []
        for d in days {
            for i in d.groups[group] ?? [] {
                guard let s = Self.date(d.date, i.from), let e = Self.date(d.date, i.to), e > s else { continue }
                list.append(PlannedOutage(start: s, end: e, maybe: i.type == "maybe"))
            }
        }
        list.sort { $0.start < $1.start }
        var merged: [PlannedOutage] = []
        for o in list {
            if var last = merged.last, o.start <= last.end, o.maybe == last.maybe {
                last.end = max(last.end, o.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(o)
            }
        }
        return merged
    }

    /// Dates (Kyiv) covered by the file.
    var dates: [String] { days.map(\.date) }

    var updated: Date? { ISO8601DateFormatter().date(from: updatedAt) }
    var fetched: Date? { ISO8601DateFormatter().date(from: fetchedAt) }
    var isEmergency: Bool { emergency?.active == true }

    /// frankov-dev/khm_outage_parser today/tomorrow files → the same model.
    static func fromFrankov(_ files: [Data]) -> RegionSchedule? {
        var days: [Day] = []
        var updated = ""
        for data in files {
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let date = o["date"] as? String, (o["available"] as? Bool) != false,
                  let queues = o["queues"] as? [String: Any] else { continue }
            if let u = o["last_updated"] as? String { updated = max(updated, u) }
            var groups: [String: [Interval]] = [:]
            for (g, q) in queues {
                let ints = ((q as? [String: Any])?["intervals"] as? [[String: Any]]) ?? []
                groups[g] = ints.compactMap { i in
                    guard let s = i["start"] as? String, let e = i["end"] as? String else { return nil }
                    let type = (i["type"] as? String ?? "").lowercased()
                    return Interval(from: s, to: e, type: type.contains("maybe") || type.contains("possib") ? "maybe" : "off")
                }
            }
            if !groups.isEmpty { days.append(Day(date: date, groups: groups)) }
        }
        guard !days.isEmpty else { return nil }
        // "2026-11-24T20:54:53.220540+02:00" → drop fractional seconds for ISO8601DateFormatter.
        let clean = updated.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return RegionSchedule(id: "khmelnytskyi", provider: "khmelnytskoblenergo",
                              sourceUrl: "https://hoe.com.ua/page/pogodinni-vidkljuchennja",
                              fetchedAt: clean, updatedAt: clean, status: "ok", emergency: nil,
                              days: days.sorted { $0.date < $1.date }, feed: "frankov")
    }
}

/// Will the battery last through a planned outage?
struct PlanForecast: Equatable {
    /// Expected charge when the outage starts, %.
    var socAtStart: Double
    /// How long the battery lasts from that charge at the current load, hours (∞ if no load).
    var runtimeHours: Double
    var outageHours: Double
    var enough: Bool { runtimeHours >= outageHours }
}

extension Station {
    /// Charging power to assume between outages: the current one if charging steadily now, otherwise the
    /// median of steady charging (≥ 300 W) seen in the last 14 days, otherwise 1 kW. Ramp-up blips right
    /// after the power comes back (a single 270 W sample) must not count as "the" charging power.
    var typicalChargeW: Double {
        if isCharging, let n = smoothedNet, n >= 300 { return n }
        let now = Date().timeIntervalSince1970
        var samples: [Double] = []
        for t in [store.raw, store.long] {
            for i in t.lowerBound(now - 14 * 86400)..<t.count { if let v = t.value("battery", at: i), v >= 300 { samples.append(v) } }
        }
        guard samples.count >= 6 else { return 1000 }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// How late the power usually comes back after a planned outage, hours (learned, 15 min…2 h; 1 h by default).
    var typicalReturnDelayHours: Double {
        guard let m = planAccuracy(days: 14)?.endDelayMin, m > 0 else { return 1 }
        return min(2, max(0.25, m / 60))
    }

    /// Steps through the schedule: the battery charges while the grid is on and drains at the current
    /// load during each outage. Returns one forecast per outage that hasn't ended yet (same order).
    func forecasts(_ plan: [PlannedOutage], now: Date = Date()) -> [PlanForecast?] {
        guard let soc0 = soc, let draw = batteryDraw ?? smoothedLoad.map({ loss.batteryDraw(output: $0) }) else {
            return plan.map { _ in nil }
        }
        let cap = capacityWh, lo = minSoc, hi = maxSoc
        let charge = typicalChargeW
        var soc = soc0
        var t = now
        // Power is out right now although no planned outage covers this moment:
        // - a planned one just ended (power is late to come back): assume it returns after the usual delay;
        // - otherwise (emergency / unscheduled): conservatively assume it stays off until the next planned outage.
        let offNow = grid.isOn == false || (grid.isOn == nil && isDischarging)
        var offUntil: Date? = nil
        if offNow, !plan.contains(where: { $0.contains(now) }) {
            if let last = plan.last(where: { $0.end <= now }), now.timeIntervalSince(last.end) < 3 * 3600 {
                offUntil = max(now, last.end.addingTimeInterval(typicalReturnDelayHours * 3600))
            } else {
                offUntil = .distantFuture
            }
        }
        return plan.map { o -> PlanForecast? in
            guard o.end > now else { return nil }
            if o.start > t {
                // Gap before this outage: drain while the power is still off, charge once it's back.
                let offEnd = min(offUntil ?? t, o.start)
                if offEnd > t {
                    soc = max(lo, soc - draw * offEnd.timeIntervalSince(t) / 3600 / cap * 100)
                    t = offEnd
                }
                let h = o.start.timeIntervalSince(t) / 3600
                if h > 0, soc < hi { soc = min(hi, soc + charge * h / cap * 100) }
            }
            offUntil = nil
            let from = max(o.start, now)
            let atStart = soc
            let remaining = o.end.timeIntervalSince(from)
            let runtime = draw < 5 ? Double.infinity : max(0, atStart - lo) / 100 * cap / draw
            soc = max(lo, soc - draw * remaining / 3600 / cap * 100)
            t = o.end
            return PlanForecast(socAtStart: atStart, runtimeHours: runtime, outageHours: remaining / 3600)
        }
    }

    /// Forecast for one outage of a plan.
    func forecast(_ o: PlannedOutage, plan: [PlannedOutage]? = nil, now: Date = Date()) -> PlanForecast? {
        let list = plan ?? [o]
        guard let i = list.firstIndex(of: o) else { return forecasts([o], now: now).first ?? nil }
        return forecasts(list, now: now)[i]
    }
}

// MARK: - What changed between two versions of a schedule

struct ScheduleChange: Equatable {
    struct Span: Equatable, Codable {
        var from: Int          // minutes from midnight
        var to: Int
        var maybe: Bool

        var text: String {
            func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
            return "\(hm(from))–\(hm(to))" + (maybe ? L(" (можливе)", " (possible)") : "")
        }
        func overlaps(_ o: Span) -> Bool { from < o.to && o.from < to }
    }

    struct Day: Equatable {
        var date: String
        /// The day wasn't in the previous version (e.g. tomorrow's schedule just came out).
        var published = false
        var spans: [Span] = []              // the new version, for "published"
        var added: [Span] = []
        var removed: [Span] = []
        var changed: [Pair] = []
        var hoursBefore = 0.0
        var hoursAfter = 0.0

        struct Pair: Equatable { var old: Span; var new: Span }
        var isEmpty: Bool { !published && added.isEmpty && removed.isEmpty && changed.isEmpty }
    }

    var days: [Day]
    var isEmpty: Bool { days.allSatisfy(\.isEmpty) }
    /// Only tomorrow's schedule appeared; nothing changed for days already known.
    var isOnlyPublication: Bool { !isEmpty && days.filter { !$0.isEmpty }.allSatisfy(\.published) }

    /// Spans of one group on one day, back-to-back pieces joined.
    static func spans(_ s: RegionSchedule?, date: String, group: String) -> [Span]? {
        guard let day = s?.days.first(where: { $0.date == date }) else { return nil }
        func min(_ hm: String) -> Int {
            let p = hm.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? p[0] * 60 + p[1] : 0
        }
        var out: [Span] = []
        for i in (day.groups[group] ?? []).sorted(by: { min($0.from) < min($1.from) }) {
            let sp = Span(from: min(i.from), to: min(i.to), maybe: i.type == "maybe")
            if var last = out.last, last.to >= sp.from, last.maybe == sp.maybe {
                last.to = Swift.max(last.to, sp.to); out[out.count - 1] = last
            } else {
                out.append(sp)
            }
        }
        return out
    }

    /// Differences for `group` on every day of `new` that isn't in the past.
    static func diff(old: RegionSchedule?, new: RegionSchedule, group: String, today: String) -> ScheduleChange {
        var days: [Day] = []
        for d in new.dates where d >= today {
            let after = spans(new, date: d, group: group) ?? []
            var day = Day(date: d)
            day.hoursAfter = hours(after)
            guard let before = spans(old, date: d, group: group) else {
                // A newly published day (only worth telling when the group has any data at all).
                if old != nil, new.days.first(where: { $0.date == d })?.groups[group] != nil {
                    day.published = true
                    day.spans = after
                    days.append(day)
                }
                continue
            }
            day.hoursBefore = hours(before)
            guard before != after else { continue }
            var unmatchedNew = after
            for o in before {
                let hits = unmatchedNew.filter { $0.overlaps(o) }
                if hits.count == 1, let n = hits.first {
                    if n != o { day.changed.append(.init(old: o, new: n)) }
                    unmatchedNew.removeAll { $0 == n }
                } else if hits.isEmpty {
                    day.removed.append(o)
                } else {
                    // One interval split into several (or the like): show it as removed + added.
                    day.removed.append(o)
                }
            }
            day.added = unmatchedNew
            if !day.isEmpty { days.append(day) }
        }
        return ScheduleChange(days: days)
    }

    static func hours(_ s: [Span]) -> Double { Double(s.filter { !$0.maybe }.reduce(0) { $0 + $1.to - $1.from }) / 60 }

    /// Human-readable lines, one per day.
    func lines(today: String, tomorrow: String) -> [String] {
        days.filter { !$0.isEmpty }.map { d in
            let label = d.date == today ? L("Сьогодні", "Today") : d.date == tomorrow ? L("Завтра", "Tomorrow")
                : Fmt.day((RegionSchedule.date(d.date, "12:00") ?? Date()).timeIntervalSince1970, "dd.MM")
            if d.published {
                return d.spans.isEmpty
                    ? L("\(label): графік опубліковано, відключень не заплановано.", "\(label): schedule published, no outages.")
                    : L("\(label): графік опубліковано — ", "\(label): schedule published — ") + d.spans.map(\.text).joined(separator: ", ") + "."
            }
            var parts: [String] = []
            parts += d.changed.map { "\($0.old.text) → \($0.new.text)" }
            if !d.added.isEmpty { parts.append(L("додано ", "added ") + d.added.map(\.text).joined(separator: ", ")) }
            if !d.removed.isEmpty { parts.append(L("скасовано ", "cancelled ") + d.removed.map(\.text).joined(separator: ", ")) }
            var line = "\(label): " + parts.joined(separator: "; ")
            if abs(d.hoursAfter - d.hoursBefore) >= 0.25 {
                func h(_ x: Double) -> String { x == x.rounded() ? "\(Int(x))" : String(format: "%.1f", x) }
                line += L(". Без світла \(h(d.hoursBefore)) → \(h(d.hoursAfter)) год", ". Without power \(h(d.hoursBefore)) → \(h(d.hoursAfter)) h")
            }
            return line + "."
        }
    }
}

extension RegionSchedule {
    /// "yyyy-MM-dd" in Kyiv for a date (+ offset days).
    static func dayString(_ d: Date = Date(), offset: Int = 0) -> String {
        let cal = kyivCalendar
        let x = cal.date(byAdding: .day, value: offset, to: d) ?? d
        let c = cal.dateComponents([.year, .month, .day], from: x)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// The primary and secondary feeds say different things about a queue on a day.
struct SourceDisagreement: Equatable {
    var date: String
    var primary: [ScheduleChange.Span]
    var secondary: [ScheduleChange.Span]
    var primaryFeed: String
    var secondaryFeed: String

    static func feedName(_ f: String?) -> String {
        switch f {
        case "frankov": "khm_outage_parser"
        case "hoe": "hoe.com.ua"
        default: "Koly Ye"
        }
    }

    static func compare(_ a: RegionSchedule, _ b: RegionSchedule, group: String, today: String) -> [SourceDisagreement] {
        a.dates.filter { $0 >= today && b.dates.contains($0) }.compactMap { d in
            guard let x = ScheduleChange.spans(a, date: d, group: group),
                  let y = ScheduleChange.spans(b, date: d, group: group),
                  b.days.first(where: { $0.date == d })?.groups[group] != nil, x != y else { return nil }
            return SourceDisagreement(date: d, primary: x, secondary: y, primaryFeed: feedName(a.feed), secondaryFeed: feedName(b.feed))
        }
    }
}
