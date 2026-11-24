// CSV export of everything JackeryBar keeps: 5-minute and 24-hour history, daily totals, outages.

import Foundation

enum Export {
    /// Writes a folder "JackeryBar-export-<date>" into `dir` (default ~/Downloads) and returns it.
    static func write(stations: [Station], tariff: TariffConfig, to dir: URL? = nil, now: Date = Date()) throws -> URL {
        let base = dir ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let out = base.appendingPathComponent("JackeryBar-export-\(f.string(from: now))")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func ts(_ t: Double) -> String { iso.string(from: Date(timeIntervalSince1970: t)) }
        func num(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }

        for st in stations {
            let name = st.name.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "_", options: .regularExpression)
            let p = "\(name)-\(st.sn.suffix(6))"
            func table(_ t: Table) -> String {
                var s = "time," + Table.columns.joined(separator: ",") + "\n"
                for i in 0..<t.count { s += ts(t.times[i]) + "," + Table.columns.map { num(t.value($0, at: i)) }.joined(separator: ",") + "\n" }
                return s
            }
            try table(st.store.long).write(to: out.appendingPathComponent("\(p)-history-5min.csv"), atomically: true, encoding: .utf8)
            try table(st.store.raw).write(to: out.appendingPathComponent("\(p)-history-24h.csv"), atomically: true, encoding: .utf8)

            var daily = "date,consumed_kWh,battery_out_kWh,battery_in_kWh,grid_in_kWh,grid_out_kWh,solar_kWh,outage_hours,cost_\(tariff.currency)\n"
            for d in st.store.daily(days: 365, now: now.timeIntervalSince1970, tariff: tariff) where d.hasData {
                let off = st.grid.summary(from: d.dayStart, to: min(d.dayStart + 86400, now.timeIntervalSince1970)).total / 3600
                daily += [String(ts(d.dayStart).prefix(10)), d.consumed, d.discharged, d.charged, d.imported, d.exported, d.solar, off, d.cost]
                    .map { ($0 as? Double).map { String(format: "%.3f", $0) } ?? "\($0)" }.joined(separator: ",") + "\n"
            }
            try daily.write(to: out.appendingPathComponent("\(p)-daily.csv"), atomically: true, encoding: .utf8)

            var outages = "start,end,duration_min,battery_used_kWh,consumed_kWh,soc_start,soc_end,approx_start\n"
            for o in st.grid.outages {
                let s = st.series(for: o)?.stats(duration: o.duration)
                outages += [ts(o.start), o.end.map(ts) ?? "", String(format: "%.0f", o.duration / 60),
                            s.map { String(format: "%.3f", $0.usedKWh) } ?? "", s.map { String(format: "%.3f", $0.consumedKWh) } ?? "",
                            num(s?.socStart), num(s?.socEnd), o.approx == true ? "yes" : ""].joined(separator: ",") + "\n"
            }
            try outages.write(to: out.appendingPathComponent("\(p)-outages.csv"), atomically: true, encoding: .utf8)
        }
        return out
    }
}
