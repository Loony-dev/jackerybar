// Tests for the UI-free core. Run with ./scripts/test.sh (no Xcode project needed).

import Foundation

var failures = 0
var checks = 0
var currentTest = ""

func check(_ cond: @autoclosure () -> Bool, _ msg: String = "", file: String = #fileID, line: Int = #line) {
    checks += 1
    if !cond() {
        failures += 1
        print("  ✗ [\(currentTest)] \(file):\(line) \(msg)")
    }
}

func near(_ a: Double?, _ b: Double, _ eps: Double = 0.01) -> Bool { a.map { abs($0 - b) <= eps } ?? false }

func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    let before = failures
    do { try body() } catch { failures += 1; print("  ✗ [\(name)] threw \(error)") }
    print((failures == before ? "✓ " : "✗ ") + name)
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("jackerybar-tests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// MARK: - Formatting

test("durations in both languages") {
    Lang.current = .uk
    check(Fmt.duration(2 + 14.0 / 60) == "2 год 14 хв")
    check(Fmt.duration(0.5) == "30 хв")
    check(Fmt.duration(12.2) == "12 год")
    check(Fmt.durationShort(3 + 40.0 / 60) == "3г 40хв")
    check(Fmt.duration(.infinity) == "∞")
    check(Fmt.energy(kWh: 0.626) == "626 Вт·год")
    Lang.current = .en
    check(Fmt.duration(2 + 14.0 / 60) == "2h 14m")
    check(Fmt.durationShort(1.25) == "1h 15m")
    check(Fmt.watts(1234) == "1.23 kW")
    check(Fmt.energy(kWh: 1.5) == "1.50 kWh")
    Lang.current = .uk
}

// MARK: - Config

test("legacy single-station config migrates to stations[]") {
    let legacy = #"{"host":"127.0.0.1","port":1883,"username":"u","password":"p","deviceSn":"HS2C0TEST00001","token":"123","name":"Дім","capacityWh":5040,"language":"en"}"#
    let c = try JSONDecoder().decode(Config.self, from: Data(legacy.utf8))
    check(c.stations.count == 1)
    check(c.stations.first?.deviceSn == "HS2C0TEST00001")
    check(c.stations.first?.token == "123")
    check(c.stations.first?.name == "Дім")
    check(c.stations.first?.capacityWh == 5040)
    check(c.language == "en")
    // Saved in the new format and read back identically.
    let url = tmp.appendingPathComponent("config.json")
    try c.save(to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    check(text.contains("\"stations\"") && !text.contains("\"deviceSn\" : \"HS2C0TEST00001\",\n  \"host\""), "new format")
    check(Config.load(from: url) == c)
}

test("placeholder template is not a station") {
    let t = #"{"host":"192.168.1.10","deviceSn":"СЕРИЙНЫЙ_НОМЕР_СТАНЦИИ","token":"ТОКЕН_ИЗ_ПРИЛОЖЕНИЯ_JACKERY"}"#
    let c = try JSONDecoder().decode(Config.self, from: Data(t.utf8))
    check(c.stations.isEmpty)
    check(!c.isUsable)
}

// MARK: - Protocol

test("protocol topics and payloads") {
    check(JackeryProtocol.parse(topic: "hb/device/HS2C1/status", prefix: "hb")! == ("HS2C1", "status"))
    check(JackeryProtocol.parse(topic: "other/device/HS2C1/status", prefix: "hb") == nil)
    let poll = try JSONSerialization.jsonObject(with: JackeryProtocol.request(type: 25, token: "tok", messageId: 42)) as! [String: Any]
    check(poll["type"] as? Int == 25 && poll["token"] as? String == "tok" && poll["messageId"] as? Int == 42)
    check(poll["body"] is NSNull)
    let cmd = try JSONSerialization.jsonObject(with: JackeryProtocol.command(.chargeLimit(90), token: "tok")) as! [String: Any]
    let body = cmd["body"] as! [String: Any]
    check(cmd["type"] as? Int == 1 && cmd["eventId"] as? Int == 3)
    check(body["cmd"] as? Int == 5 && body["rc"] as? Int == 1 && body["socChgLimit"] as? Int == 90)
    let ac = try JSONSerialization.jsonObject(with: JackeryProtocol.command(.acOutlet(false), token: "t")) as! [String: Any]
    check((ac["body"] as! [String: Any])["swEps"] as? Int == 0)
}

// MARK: - Loss model

test("loss model: ratio, then linear fit with spread loads") {
    let m = LossModel()
    var t = Date(timeIntervalSince1970: 0)
    for _ in 0..<10 { t += 21; m.add(output: 465, battery: 512, at: t) }
    check(!m.isLinear && near(m.slope, 512.0 / 465, 0.001))
    let lin = LossModel()
    for i in 0..<60 { t += 21; let ac = 80 + Double(i % 12) * 45; lin.add(output: ac, battery: 1.05 * ac + 25, at: t) }
    check(lin.isLinear && near(lin.slope, 1.05, 0.001) && near(lin.intercept, 25, 0.1))
    let junk = LossModel(); junk.add(output: 467, battery: 1200); junk.add(output: 5, battery: 300)
    check(junk.pairs.isEmpty)
}

// MARK: - History

test("table: overwrite newest row until step, buckets and energy") {
    let tb = Table(step: 10, retention: 3600, maxGap: 60)
    tb.record(at: 0, values: ["ac": 100])
    tb.record(at: 5, values: ["ac": 100])
    tb.record(at: 8, values: ["ac": 100])     // overwrites the row at 5
    check(tb.count == 2 && tb.times.last == 8)
    for s in stride(from: 10.0, through: 3600, by: 10) { tb.record(at: s, values: ["ac": 100]) }
    // 100 W for an hour = 0.1 kWh
    let st = tb.stats("ac", from: 0, to: 3600, transform: { $0 })!
    check(near(st.posKWh, 0.1, 0.002), "energy \(st.posKWh)")
    check(st.min == 100 && st.max == 100)
    let b = tb.buckets("ac", from: 0, to: 3600, count: 6, transform: { $0 })
    check(b.count == 6 && b.allSatisfy { $0 == 100 })
}

test("table: gaps are not integrated") {
    let tb = Table(step: 10, retention: 86400, maxGap: 60)
    tb.record(at: 0, values: ["ac": 1000])
    tb.record(at: 30, values: ["ac": 1000])
    tb.record(at: 3600, values: ["ac": 1000])   // 1 h gap
    let st = tb.stats("ac", from: 0, to: 4000, transform: { $0 })!
    check(near(st.posKWh, 1000 * 30 / 3600 / 1000, 0.0001), "only the 30 s before the gap count")
}

test("metric store: 5-minute rollup, daily energy, persistence, backfill") {
    let ms = MetricStore()
    let day0 = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 - 86400   // yesterday 00:00
    // Yesterday 10:00–12:00: 500 W out of the battery, 450 W at the outlet.
    for s in stride(from: 0.0, to: 7200, by: 10) {
        ms.record(at: Date(timeIntervalSince1970: day0 + 36000 + s), values: ["battery": -500, "ac": 450, "soc": 80])
    }
    ms.record(at: Date(timeIntervalSince1970: day0 + 50000), values: ["ac": 0])   // closes the last bucket
    check(ms.long.count >= 24, "\(ms.long.count) five-minute rows")
    let days = ms.daily(days: 2, now: day0 + 86400 + 3600)
    check(days.count == 2 && days[0].hasData && !days[1].hasData)
    check(near(days[0].discharged, 1.0, 0.02), "discharged \(days[0].discharged)")
    check(near(days[0].consumed, 0.9, 0.02), "consumed \(days[0].consumed)")
    // Long ranges come from the 5-minute table.
    check(ms.table(from: day0, now: day0 + 3 * 86400) === ms.long)
    check(ms.table(from: day0 + 3 * 86400 - 3600, now: day0 + 3 * 86400) === ms.raw)

    let raw = tmp.appendingPathComponent("m.json"), long = tmp.appendingPathComponent("l.json")
    ms.save(raw: raw, long: long)
    let again = MetricStore()
    again.long.load(from: long)
    check(again.long.count == ms.long.count)

    // No long-term file yet: 5-minute rows are rebuilt from the raw 24 h.
    let fresh = MetricStore()
    let now = Date().timeIntervalSince1970
    for s in stride(from: 0.0, to: 1800, by: 10) { fresh.raw.record(at: now - 1800 + s, values: ["ac": 200]) }
    fresh.raw.save(to: raw)
    try? FileManager.default.removeItem(at: long)
    let back = MetricStore()
    back.load(raw: raw, long: long)
    check(back.long.count >= 5, "backfilled \(back.long.count)")
}

// MARK: - Outages

test("grid log: debounce, outage open/close, restart during outage") {
    let g = GridLog()
    var events: [(Bool, Double?)] = []
    g.onChange = { on, ended in events.append((on, ended?.duration)) }
    let t0 = Date().timeIntervalSince1970 - 10000
    g.update(true, at: t0); g.update(true, at: t0 + 5)          // initial state: no event
    check(g.isOn == true && events.isEmpty)
    g.update(false, at: t0 + 100)                                 // single blip ignored
    g.update(true, at: t0 + 105)
    check(g.isOn == true && g.outages.isEmpty)
    g.update(false, at: t0 + 200); g.update(false, at: t0 + 205)
    check(g.isOn == false && g.outages.count == 1 && events.count == 1 && events[0].0 == false)
    g.update(true, at: t0 + 3800); g.update(true, at: t0 + 3805)
    check(g.isOn == true && g.outages[0].end == t0 + 3800 && events.count == 2)
    check(near(events[1].1, 3600, 0.5))

    // Restart while an outage is open: the same outage continues, no duplicate.
    let url = tmp.appendingPathComponent("o.json")
    g.update(false, at: t0 + 5000); g.update(false, at: t0 + 5005)
    g.save(to: url)
    let r = GridLog(); r.load(from: url)
    r.update(false, at: t0 + 6000); r.update(false, at: t0 + 6005)
    check(r.outages.count == 2 && r.outages.last?.end == nil && r.since == t0 + 5000)
    let sum = r.summary(from: t0, to: t0 + 6000)
    check(sum.count == 2 && near(sum.total, 3600 + 1000, 1))
}

test("outage series stats") {
    let s = OutageSeries(t0: 0, step: 60, ac: Array(repeating: 450, count: 60), bat: Array(repeating: -500, count: 60),
                         soc: (0..<60).map { 80 - Double($0) * 0.2 }, temp: Array(repeating: 28, count: 60))
    let st = s.stats(duration: 3600)
    check(near(st.consumedKWh, 0.45) && near(st.usedKWh, 0.5))
    check(near(st.efficiency, 0.9) && near(st.socStart, 80) && near(st.socEnd, 68.2))
    check(near(st.socPerHour, 11.8, 0.05))
}

// MARK: - Station

test("station: ingest, CT filtering, token rejection, runtime, outages") {
    let st = Station(config: StationConfig(deviceSn: "HS2C0TEST00001", token: "t"))
    let now = Date()
    check(st.ingest(["type": 106, "body": ["soc": 64, "batInPw": 0, "batOutPw": 500, "swEpsOutPw": 450,
                                           "socDischgLimit": 10, "batNum": 1, "ongridStat": 0] as [String: Any]], at: now) == .data)
    check(st.capacityWh == 5040)
    check(near(st.runtimeHours, (64 - 10) / 100 * 5040 / 500, 0.001))
    check(st.ingest(["type": 23, "body": ["deviceSn": "CT999", "soc": 1] as [String: Any]]) == .ignored)
    check(st.soc == 64, "CT message must not overwrite the station")
    check(st.ingest(["type": 123, "body": ["errorCode": 401]]) == .tokenRejected)
    check(st.tokenRejected)
    _ = st.ingest(["type": 106, "body": ["soc": 63, "ongridStat": 0] as [String: Any]], at: now + 5)
    check(!st.tokenRejected && st.grid.isOn == false, "two readings → outage known")
}

test("station: pending commands resolve or fail") {
    let st = Station(config: StationConfig(deviceSn: "HS2C0TEST00001", token: "t"))
    let t = Date()
    st.markSent(.chargeLimit(90), at: t)
    check(st.isPending("socChgLimit"))
    _ = st.ingest(["type": 2, "body": ["socChgLimit": 100, "soc": 50] as [String: Any]], at: t + 5)
    check(st.isPending("socChgLimit"), "old value — still waiting")
    _ = st.ingest(["type": 2, "body": ["socChgLimit": 90, "soc": 50] as [String: Any]], at: t + 10)
    check(!st.isPending("socChgLimit") && st.failedCommand == nil)
    st.markSent(.acOutlet(false), at: t)
    _ = st.ingest(["type": 2, "body": ["swEps": 1, "soc": 50] as [String: Any]], at: t + 40)
    check(!st.isPending("swEps") && st.failedCommand == "swEps")
}

test("low-battery alerts fire once per threshold and re-arm") {
    var tr = LowBatteryTracker()
    check(tr.check(soc: 50, discharging: true, thresholds: [30, 15]) == nil)
    check(tr.check(soc: 30, discharging: true, thresholds: [30, 15]) == 30)
    check(tr.check(soc: 29, discharging: true, thresholds: [30, 15]) == nil)
    check(tr.check(soc: 14, discharging: true, thresholds: [30, 15]) == 15)
    check(tr.check(soc: 10, discharging: false, thresholds: [30, 15]) == nil)
    _ = tr.check(soc: 40, discharging: false, thresholds: [30, 15])          // recharged above 30+5
    check(tr.check(soc: 30, discharging: true, thresholds: [30, 15]) == 30)
    var jump = LowBatteryTracker()
    check(jump.check(soc: 12, discharging: true, thresholds: [30, 15]) == 15, "skipping a level reports the lowest")
    check(jump.check(soc: 11, discharging: true, thresholds: [30, 15]) == nil)
}

// MARK: - Discovery

test("discovery parses Mosquitto connection log") {
    let log = """
    1795544090: New client connected from 127.0.0.1:65123 as auto-1525F860-5AB5-9891-294E-F855C904517C (p4, c1, k60, u'jackery').
    1795544100: New client connected from 127.0.0.1:65124 as jackerybar-1A2B3C4D (p4, c1, k30, u'jackery').
    1795544123: New client connected from 192.168.1.77:52042 as HS2C0TEST00001 (p4, c1, k60, u'jackery').
    1795544200: New client connected from 192.168.0.12:40000 as HS2C0TEST00002 (p4, c1, k60, u'jackery').
    1795544300: New client connected from 192.168.1.78:52043 as HS2C0TEST00001 (p4, c1, k60, u'jackery').
    """
    let found = Discovery.parse(log)
    check(found.map(\.sn) == ["HS2C0TEST00001", "HS2C0TEST00002"], "\(found.map(\.sn))")
    check(found.first?.ip == "192.168.1.78" && found.first?.seen == 1795544300)
    check(!Discovery.looksLikeSerial("jackerybar-1A2B3C4D") && !Discovery.looksLikeSerial("ABCDEFGHIJKLMN"))
}

// MARK: - Planned outages

test("koly schedule: absolute times, merge across midnight, maybe") {
    let json = #"""
    {"id":"khmelnytskyi","provider":"khmelnytskoblenergo","sourceUrl":"https://hoe.com.ua/x","fetchedAt":"2026-11-24T20:31:13+02:00",
     "updatedAt":"2026-11-24T20:19:00+02:00","status":"ok","emergency":{"active":false,"note":null,"since":null},
     "days":[{"date":"2026-11-24","groups":{"1.1":[{"from":"04:00","to":"07:00","type":"off"},{"from":"22:00","to":"24:00","type":"off"}],
                                             "2.1":[{"from":"12:00","to":"13:00","type":"maybe"}]}},
             {"date":"2026-11-25","groups":{"1.1":[{"from":"00:00","to":"02:00","type":"off"},{"from":"16:00","to":"20:00","type":"off"}]}}]}
    """#
    let s = try JSONDecoder().decode(RegionSchedule.self, from: Data(json.utf8))
    check(s.groups == ["1.1", "2.1"])
    let o = s.outages(group: "1.1")
    check(o.count == 3, "22–24 and 00–02 merge: \(o.count)")
    let kyiv = RegionSchedule.kyivCalendar
    check(kyiv.component(.hour, from: o[0].start) == 4 && kyiv.component(.hour, from: o[0].end) == 7)
    check(o[1].duration == 4 * 3600, "22:00–02:00 = 4 h")
    check(s.outages(group: "2.1").first?.maybe == true)
    check(s.updated != nil)
    check(RegionSchedule.groupLess("1.2", "2.1") && RegionSchedule.groupLess("2.1", "10.1"))
}

test("frankov today/tomorrow → same model") {
    let today = #"{"date":"2026-11-24","is_today":true,"last_updated":"2026-11-24T20:54:53.220540+02:00","queues":{"1.1":{"intervals":[{"start":"04:00","end":"07:00","type":"base"}]}}}"#
    let tomorrow = #"{"date":"2026-11-25","available":true,"queues":{"1.1":{"intervals":[{"start":"06:00","end":"09:00","type":"base"}]}}}"#
    let none = #"{"date":"2026-11-26","available":false,"queues":{}}"#
    let s = RegionSchedule.fromFrankov([Data(today.utf8), Data(tomorrow.utf8), Data(none.utf8)])!
    check(s.days.count == 2 && s.feed == "frankov" && s.outages(group: "1.1").count == 2)
    check(s.updated != nil, "fractional seconds handled")
}

test("forecast: charge before the outage, then runtime at the current load") {
    let st = Station(config: StationConfig(deviceSn: "HS2C0TEST00001", token: "t"))
    let now = Date()
    // Charging at 1000 W from 50 %, 2.52 kWh, load 200 W, limits 10…100 %.
    st.inject(values: ["soc": 50, "socDischgLimit": 10, "socChgLimit": 100, "batInPw": 1000, "swEpsOutPw": 200, "batNum": 0],
              net: 1000, load: 200, at: now)
    let o = PlannedOutage(start: now + 3600, end: now + 3 * 3600, maybe: false)
    let f = st.forecast(o, now: now)!
    check(near(f.socAtStart, 50 + 1000.0 / 2520 * 100, 0.1), "\(f.socAtStart)")
    let draw = st.loss.batteryDraw(output: 200)
    check(near(f.runtimeHours, (f.socAtStart - 10) / 100 * 2520 / draw, 0.01))
    check(f.outageHours == 2 && f.enough)
    // Nearly empty and discharging hard: not enough.
    st.inject(values: ["soc": 14, "socDischgLimit": 10, "batOutPw": 900, "swEpsOutPw": 820], net: -900, load: 820, at: now)
    let g = st.forecast(PlannedOutage(start: now + 600, end: now + 4 * 3600, maybe: false), now: now)!
    check(!g.enough && g.socAtStart < 14)
}

test("forecast steps through the plan: recharge between outages") {
    let st = Station(config: StationConfig(deviceSn: "HS2C0TEST00001", token: "t"))
    let now = Date()
    // Outage now at 500 W from 60 %; grid back in 1 h; next outage 10 h later.
    st.inject(values: ["soc": 60, "socDischgLimit": 10, "socChgLimit": 100, "batOutPw": 500, "swEpsOutPw": 460, "ongridStat": 0, "batNum": 0],
              net: -500, load: 460, at: now)
    let plan = [PlannedOutage(start: now - 1800, end: now + 3600, maybe: false),
                PlannedOutage(start: now + 11 * 3600, end: now + 15 * 3600, maybe: false)]
    let f = st.forecasts(plan, now: now)
    check(f.count == 2 && f[0] != nil && f[1] != nil)
    check(near(f[0]!.socAtStart, 60) && near(f[0]!.outageHours, 1, 0.01), "current outage: from now")
    check(f[1]!.socAtStart > 99, "recharged to the limit before the next one: \(f[1]!.socAtStart)")
    check(f[1]!.enough)
}

test("queue is changed in place for the station") {
    let hub = Hub()
    let st = Station(config: StationConfig(deviceSn: "HS2C0TEST00001", token: "t"))
    hub.showPreview([st], selected: st.sn)
    check(st.config.scheduleRegion == nil)
    hub.setQueue(st.sn, region: "khmelnytskyi", queue: "2.1")
    check(st.config.queue == "2.1" && st.config.scheduleRegion == "khmelnytskyi")
    check(hub.config?.stations.first?.queue == "2.1")
    hub.setQueue(st.sn, region: nil, queue: nil)
    check(st.config.queue == nil && st.config.region == nil)
}

test("schedule diff: changed, added, removed, published, hours") {
    func sched(_ days: [(String, [(String, String, String)])]) -> RegionSchedule {
        RegionSchedule(id: "khmelnytskyi", provider: "p", sourceUrl: "", fetchedAt: "", updatedAt: "", status: "ok", emergency: nil,
                       days: days.map { d in .init(date: d.0, groups: ["1.1": d.1.map { .init(from: $0.0, to: $0.1, type: $0.2) }]) }, feed: nil)
    }
    let old = sched([("2026-11-24", [("04:00", "07:00", "off"), ("19:00", "22:00", "off")])])
    let new = sched([("2026-11-24", [("04:00", "07:00", "off"), ("18:00", "22:00", "off"), ("23:00", "24:00", "off")]),
                     ("2026-11-25", [("06:00", "09:00", "off")])])
    let ch = ScheduleChange.diff(old: old, new: new, group: "1.1", today: "2026-11-24")
    check(!ch.isEmpty && !ch.isOnlyPublication && ch.days.count == 2)
    let d = ch.days[0]
    check(d.changed.count == 1 && d.changed[0].old.from == 19 * 60 && d.changed[0].new.from == 18 * 60)
    check(d.added.count == 1 && d.added[0].from == 23 * 60 && d.removed.isEmpty)
    check(d.hoursBefore == 6 && d.hoursAfter == 8)
    check(ch.days[1].published && ch.days[1].spans.count == 1)
    Lang.current = .uk
    let lines = ch.lines(today: "2026-11-24", tomorrow: "2026-11-25")
    check(lines[0] == "Сьогодні: 19:00–22:00 → 18:00–22:00; додано 23:00–24:00. Без світла 6 → 8 год.", lines[0])
    check(lines[1] == "Завтра: графік опубліковано — 06:00–09:00.", lines[1])
    // Cancelled, and past days are ignored.
    let cancel = ScheduleChange.diff(old: new, new: sched([("2026-11-25", [])]), group: "1.1", today: "2026-11-25")
    check(cancel.days.count == 1 && cancel.days[0].removed.count == 1)
    check(ScheduleChange.diff(old: old, new: old, group: "1.1", today: "2026-11-24").isEmpty)
    check(ScheduleChange.diff(old: nil, new: new, group: "1.1", today: "2026-11-24").isEmpty, "first copy: nothing to compare")
    // Only tomorrow appeared → publication.
    let pub = ScheduleChange.diff(old: old, new: sched([("2026-11-24", [("04:00", "07:00", "off"), ("19:00", "22:00", "off")]), ("2026-11-25", [])]),
                                  group: "1.1", today: "2026-11-24")
    check(pub.isOnlyPublication)
}

test("hub reports schedule changes per station queue") {
    let hub = Hub()
    let a = Station(config: StationConfig(deviceSn: "HS2C0TEST00001", token: "t", region: "khmelnytskyi", queue: "1.1"))
    let b = Station(config: StationConfig(deviceSn: "HS2C0TEST00002", token: "t", region: "khmelnytskyi", queue: "2.1"))
    hub.showPreview([a, b], selected: a.sn)
    var got: [String] = []
    hub.onScheduleChanged = { st, _ in got.append(st.sn) }
    let today = RegionSchedule.dayString()
    func s(_ to11: String) -> RegionSchedule {
        RegionSchedule(id: "khmelnytskyi", provider: "p", sourceUrl: "", fetchedAt: "", updatedAt: "", status: "ok", emergency: nil,
                       days: [.init(date: today, groups: ["1.1": [.init(from: "10:00", to: to11, type: "off")],
                                                          "2.1": [.init(from: "12:00", to: "14:00", type: "off")]])], feed: nil)
    }
    hub.scheduleChanged("khmelnytskyi", old: s("12:00"), new: s("13:00"))
    check(got == ["HS2C0TEST00001"], "only the queue that changed: \(got)")
    check(a.lastScheduleChange != nil && b.lastScheduleChange == nil)
}

test("source cross-check finds disagreements per queue") {
    func sched(_ feed: String, _ g42: [(String, String)]) -> RegionSchedule {
        RegionSchedule(id: "khmelnytskyi", provider: "p", sourceUrl: "", fetchedAt: "", updatedAt: "", status: "ok", emergency: nil,
                       days: [.init(date: "2026-11-24", groups: ["4.2": g42.map { .init(from: $0.0, to: $0.1, type: "off") },
                                                                 "1.1": [.init(from: "04:00", to: "07:00", type: "off")]])], feed: feed)
    }
    // The real case from 24.11: Koly merged the intraday update into 16–24, the other parser lost 22–24.
    let koly = sched("koly", [("07:00", "12:00"), ("16:00", "24:00")])
    let fr = sched("frankov", [("07:00", "12:00"), ("16:00", "20:00")])
    let d = SourceDisagreement.compare(koly, fr, group: "4.2", today: "2026-11-24")
    check(d.count == 1 && d[0].primaryFeed == "Koly Ye" && d[0].secondaryFeed == "khm_outage_parser")
    check(d[0].primary.last?.to == 24 * 60 && d[0].secondary.last?.to == 20 * 60)
    check(SourceDisagreement.compare(koly, fr, group: "1.1", today: "2026-11-24").isEmpty, "same for 1.1")
    check(SourceDisagreement.compare(koly, fr, group: "4.2", today: "2026-11-25").isEmpty, "past days ignored")
    let svc = ScheduleService()
    svc.inject(koly); svc.injectSecondary(fr)
    check(svc.disagreements("khmelnytskyi", group: "4.2", today: "2026-11-24").count == 1)
}

// MARK: - Address book

test("address normalization and search") {
    check(AddressBook.normalizeHouse(" 10-а") == "10А" && AddressBook.normalizeHouse("53\\1") == "53/1")
    check(AddressBook.normalizeName("вул. Грушевського М.") == "грушевського")
    check(AddressBook.normalizeName("пров. Кам’янецький") == AddressBook.normalizeName("Кам'янецький"))
    let e = AddressBook.entry(from: ["Загінці", "вул. Берегова", " 1, 10, 12, 4/1, 10-а", "1.1. підчерга"])!
    check(e.queue == "1.1" && e.houses.contains("10А") && e.houses.contains("4/1"))
    check(AddressBook.entry(from: ["Населений пункт", "Вулиця", "Список будинків", "Черга/підчерга"]) == nil)
    check(AddressBook.districtName("/Content/Uploads/GPV6/xls/Черги_на_відключення_Хмельницький_РЕМ_побут_09102026.xlsx") == "Хмельницький РЕМ побут")
}

test("newest district files are picked from the page") {
    let html = #"""
    <a href="/Content/Uploads/GPV6/xls/Черги_на_відключення_Летичівський_РЕМ_01092026.xlsx">a</a>
    <a href="/Content/Uploads/GPV6/xls/Черги_на_відключення_Летичівський_РЕМ_09102026.xlsx">b</a>
    <a href="/Content/Uploads/GPV6/xls/%D0%A7%D0%B5%D1%80%D0%B3%D0%B8_на_відключення_Городоцький_РЕМ_09102026.xlsx">c</a>
    <a href="/Content/Uploads/GPV6/pdf/Черги_на_відключення_Городоцький_РЕМ_09102026.pdf">pdf</a>
    """#
    let f = AddressBook.newestFiles(in: html)
    check(f.count == 2, "\(f)")
    check(f.contains { $0.hasSuffix("Летичівський_РЕМ_09102026.xlsx") })
}

test("xlsx sheet parsing (shared strings + numbers)") {
    let ss = Data(#"<sst><si><t>Загінці</t></si><si><t>вул. Берегова</t></si><si><r><t>1, </t></r><r><t>2</t></r></si><si><t>2.1. підчерга</t></si></sst>"#.utf8)
    let strings = XLSX.parseSharedStrings(ss)
    check(strings == ["Загінці", "вул. Берегова", "1, 2", "2.1. підчерга"])
    let sheet = Data(#"<worksheet><sheetData><row r="4"><c r="A4" t="s"><v>0</v></c><c r="B4" t="s"><v>1</v></c><c r="C4"><v>7</v></c><c r="D4" t="s"><v>3</v></c></row></sheetData></worksheet>"#.utf8)
    let rows = XLSX.parseSheet(sheet, strings: strings)
    check(rows == [["Загінці", "вул. Берегова", "7", "2.1. підчерга"]], "\(rows)")
}

try? FileManager.default.removeItem(at: tmp)
print("\n\(checks - failures)/\(checks) checks passed" + (failures == 0 ? "" : ", \(failures) FAILED"))
exit(failures == 0 ? 0 : 1)
