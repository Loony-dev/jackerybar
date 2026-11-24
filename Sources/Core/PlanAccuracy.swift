// How well the schedule matched reality: planned outages (kept per day in the station's plan log)
// against the outages the station actually saw.

import Foundation

struct PlanAccuracy: Equatable {
    var days: Int
    var plannedHours = 0.0
    var actualHours = 0.0
    var matchedHours = 0.0
    /// Average minutes the power actually went off after (+) / before (−) the planned start.
    var startDelayMin: Double?
    /// Average minutes the power actually came back after (+) / before (−) the planned end.
    var endDelayMin: Double?

    /// Off without a planned outage.
    var unplannedHours: Double { max(0, actualHours - matchedHours) }
    /// Planned, but the power stayed on.
    var sparedHours: Double { max(0, plannedHours - matchedHours) }
    /// Share of time that was off in the plan or in reality, where both agreed.
    var match: Double? {
        let union = plannedHours + actualHours - matchedHours
        return union > 0.05 ? matchedHours / union : nil
    }
}

extension Station {
    /// Plan vs fact over the last `days` days (today included up to now), only where outages were being tracked.
    func planAccuracy(days: Int = 7, now: Date = Date()) -> PlanAccuracy? {
        guard let tracking = grid.trackingSince else { return nil }
        var r = PlanAccuracy(days: days)
        var starts: [Double] = [], ends: [Double] = []
        var anyDay = false
        let nowT = now.timeIntervalSince1970
        for k in 0..<days {
            let date = RegionSchedule.dayString(now, offset: -k)
            guard let spans = planLog[date], let dayStart = RegionSchedule.date(date, "00:00")?.timeIntervalSince1970 else { continue }
            let from = max(dayStart, tracking), to = min(dayStart + 86400, nowT)
            guard to > from else { continue }
            anyDay = true
            let planned = spans.filter { !$0.maybe }.compactMap { s -> (Double, Double)? in
                let a = max(dayStart + Double(s.from * 60), from), b = min(dayStart + Double(s.to * 60), to)
                return b > a ? (a, b) : nil
            }
            let actual = grid.outages(from: from, to: to).map { ($0.start, $0.end) }
            r.plannedHours += planned.reduce(0) { $0 + $1.1 - $1.0 } / 3600
            r.actualHours += actual.reduce(0) { $0 + $1.1 - $1.0 } / 3600
            for p in planned {
                for a in actual { r.matchedHours += max(0, min(p.1, a.1) - max(p.0, a.0)) / 3600 }
            }
            // Delays: each actual outage is paired with the one planned outage it overlaps most; its start (end)
            // counts only within 1.5 h of the planned one, so one outage isn't blamed on several plans.
            let plannedAbs = spans.filter { !$0.maybe }.map { (dayStart + Double($0.from * 60), dayStart + Double($0.to * 60)) }
            for o in grid.outages where o.start >= from && o.start < to {
                let oe = o.end ?? nowT
                guard let (ps, pe) = plannedAbs.map({ p in (p, max(0, min(p.1, oe) - max(p.0, o.start))) })
                        .filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 })?.0 else { continue }
                if abs(o.start - ps) <= 5400 { starts.append((o.start - ps) / 60) }
                if let e = o.end, abs(e - pe) <= 5400 { ends.append((e - pe) / 60) }
            }
        }
        guard anyDay else { return nil }
        r.startDelayMin = starts.isEmpty ? nil : starts.reduce(0, +) / Double(starts.count)
        r.endDelayMin = ends.isEmpty ? nil : ends.reduce(0, +) / Double(ends.count)
        return r
    }
}
