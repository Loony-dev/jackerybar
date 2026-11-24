// Demo stations for README screenshots (`--render-panel`). Never contains real identifiers.

import Foundation

enum PreviewData {
    /// "Дім" during an outage (30 days of history, a week of outages) and "Гараж" charging from the grid.
    static func stations() -> [Station] {
        let home = Station(config: StationConfig(deviceSn: "HS2C0DEMO000001", token: "00000000", name: L("Дім", "Home"),
                                                 capacityWh: nil, moduleWh: 2520, region: "khmelnytskyi", queue: "1.1"))
        let garage = Station(config: StationConfig(deviceSn: "HS2C0DEMO000002", token: "00000000", name: L("Гараж", "Garage"),
                                                   capacityWh: nil, moduleWh: 2520, region: "khmelnytskyi", queue: "3.2"))
        seedHome(home)
        seedGarage(garage)
        return [home, garage]
    }

    private static func seedHome(_ st: Station) {
        let now = Date().timeIntervalSince1970
        let ongoingStart = now - 4300
        // Past outages: (days ago, start hour, hours).
        let past: [(Int, Double, Double)] = [(29, 9, 3), (27, 18, 4), (24, 6, 2.5), (22, 14, 4), (19, 20, 3), (17, 8, 2),
                                             (14, 16, 3.5), (12, 5, 4), (10, 19, 2.5), (8, 11, 3), (6, 9, 4), (4, 18, 4),
                                             (2, 5, 4), (1, 14, 2.5)]
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let outages = past.map { (d, h, len) -> (Double, Double) in
            let s = today - Double(d) * 86400 + h * 3600
            return (s, s + len * 3600)
        }
        func inOutage(_ t: Double) -> Bool { t >= ongoingStart || outages.contains { t >= $0.0 && t < $0.1 } }
        func load(_ t: Double) -> Double {
            let h = (t - Calendar.current.startOfDay(for: Date(timeIntervalSince1970: t)).timeIntervalSince1970) / 3600
            let day = (t / 86400).rounded(.down)
            let mood = 0.75 + 0.5 * abs(sin(day * 1.7)) + (Int(day) % 7 >= 5 ? 0.3 : 0)   // busier weekends, day-to-day spread
            return (160 + 140 * max(0, sin((h - 7) / 14 * .pi)) + (h > 18 && h < 22 ? 220 : 0)) * mood + 40 * sin(t / 1700)
        }

        st.grid.update(true, at: now - 31 * 86400); st.grid.update(true, at: now - 31 * 86400 + 5)
        var soc = 90.0
        var nextOutage = 0
        // 30 days at 5-minute resolution, then the last 2 hours at 5 s.
        var t = now - 30 * 86400
        while t < now {
            let step: Double = t < now - 7200 ? 300 : 5
            while nextOutage < outages.count, outages[nextOutage].0 <= t {
                st.grid.update(false, at: outages[nextOutage].0); st.grid.update(false, at: outages[nextOutage].0 + 5)
                st.grid.update(true, at: outages[nextOutage].1); st.grid.update(true, at: outages[nextOutage].1 + 5)
                nextOutage += 1
            }
            let l = load(t) + (t > now - 2000 && t < now - 1700 ? 700 : 0)
            var v: [String: Double] = ["ac": l, "temp": 26 + 3 * sin(t / 40000), "wifi": -41]
            if inOutage(t) {
                let bat = -(l * 1.08 + 22)
                soc = max(10, soc + bat * step / 3600 / 2520 * 100)
                v["battery"] = bat; v["grid"] = 0
                if step == 5, Int(t) % 25 == 0 { st.loss.add(output: l, battery: -bat, at: Date(timeIntervalSince1970: t)) }
            } else {
                let charge = soc < 100 ? 900.0 : 0
                soc = min(100, soc + charge * step / 3600 / 2520 * 100)
                v["battery"] = charge; v["grid"] = l + charge
            }
            v["soc"] = soc
            st.store.record(at: Date(timeIntervalSince1970: t), values: v)
            t += step
        }
        st.grid.update(false, at: ongoingStart); st.grid.update(false, at: ongoingStart + 5)
        let l = 440.0
        st.inject(values: ["soc": soc, "batNum": 0, "socDischgLimit": 10, "socChgLimit": 100, "batInPw": 0,
                           "batOutPw": l * 1.08 + 22, "gridInPw": 0, "gridOutPw": 0, "ongridStat": 0,
                           "swEpsInPw": 0, "swEpsOutPw": l, "pvPw": 0, "swEps": 1, "maxOutPw": 800,
                           "cellTemp": 297, "minCellTemp": 284, "maxCellTemp": 301, "wsig": -41],
                  net: -(l * 1.08 + 22), load: l)
    }

    /// A plausible Khmelnytskyi schedule for today and tomorrow, aligned with the demo outage.
    static func schedule() -> (RegionSchedule, [RegionInfo]) {
        let cal = RegionSchedule.kyivCalendar
        let now = Date()
        let h = cal.component(.hour, from: now)
        func day(_ offset: Int) -> String {
            let d = cal.date(byAdding: .day, value: offset, to: now)!
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        func i(_ a: Int, _ b: Int, _ maybe: Bool = false) -> RegionSchedule.Interval {
            .init(from: String(format: "%02d:00", max(0, min(23, a))), to: String(format: "%02d:00", max(1, min(24, b))), type: maybe ? "maybe" : "off")
        }
        // Queue 1.1: an early outage, one going on now (the demo station is on battery), one tonight.
        var today11 = [i(4, 7)]
        if h - 1 > 7 { today11.append(i(h - 1, min(24, h + 3))) }
        if h + 5 < 24 { today11.append(i(h + 5, min(24, h + 7), true)) }
        let today32 = h + 2 < 23 ? [i(1, 4), i(h + 2, min(24, h + 5))] : [i(1, 4)]
        let days = [
            RegionSchedule.Day(date: day(0), groups: ["1.1": today11, "3.2": today32]),
            RegionSchedule.Day(date: day(1), groups: ["1.1": [i(6, 9), i(16, 20)], "3.2": [i(9, 13), i(20, 24)]]),
        ]
        let iso = ISO8601DateFormatter()
        iso.timeZone = RegionSchedule.kyiv
        let stamp = iso.string(from: now.addingTimeInterval(-1200))
        let s = RegionSchedule(id: "khmelnytskyi", provider: "khmelnytskoblenergo", sourceUrl: "https://hoe.com.ua/page/pogodinni-vidkljuchennja",
                               fetchedAt: stamp, updatedAt: stamp, status: "ok", emergency: .init(), days: days, feed: "koly")
        let info = RegionInfo(id: "khmelnytskyi", name: .init(uk: "Хмельницька", en: "Khmelnytskyi", ru: nil), provider: "khmelnytskoblenergo",
                              groups: ["1.1", "1.2", "2.1", "2.2", "3.1", "3.2", "4.1", "4.2", "5.1", "5.2", "6.1", "6.2"], updatedAt: stamp, status: "ok")
        return (s, [info])
    }

    private static func seedGarage(_ st: Station) {
        let now = Date().timeIntervalSince1970
        var soc = 31.0
        for i in 0..<1440 {
            let t = now - 7200 + Double(i) * 5
            soc = min(100, soc + 1070 * 5 / 3600 / 2520 * 100 * 0.5)
            st.store.record(at: Date(timeIntervalSince1970: t), values: ["battery": 1070, "grid": 1150, "ac": 80, "soc": soc, "temp": 24])
        }
        st.grid.update(true, at: now - 7200); st.grid.update(true, at: now - 7195)
        st.inject(values: ["soc": 64, "batNum": 1, "socDischgLimit": 10, "socChgLimit": 100, "batInPw": 1070, "batOutPw": 0,
                           "gridInPw": 1150, "gridOutPw": 0, "ongridStat": 1, "swEpsInPw": 0, "swEpsOutPw": 80, "pvPw": 0,
                           "cellTemp": 241, "minCellTemp": 236, "maxCellTemp": 246, "wsig": -58, "swEps": 1],
                  net: 1070, load: 80)
    }
}
