// One SolarVault station: live values from MQTT, smoothed power, runtime estimate,
// history, outage log, loss model, low-battery alerts and pending commands.

import Foundation

final class Station {
    private(set) var config: StationConfig
    let tau: Double

    private(set) var values: [String: Double] = [:]
    private(set) var lastUpdate: Date?
    /// Battery power, W: + charging / − discharging (smoothed).
    private(set) var smoothedNet: Double?
    /// Power delivered to consumers (AC outlet + grid port output), W (smoothed).
    private(set) var smoothedLoad: Double?
    private var lastSample: Date?
    private(set) var softver: String?
    /// The station answered "401": the token is wrong.
    private(set) var tokenRejected = false
    /// True once the station reported PV power (AC-only models never do).
    private(set) var pvSeen = false

    let loss = LossModel()
    /// History of every metric: 24 h raw + 1 year of 5-minute averages.
    let store = MetricStore()
    /// Mains presence and the outage log.
    let grid = GridLog()
    var lowBattery = LowBatteryTracker()
    /// Start times of planned outages already announced ("in 30 min…").
    var announcedPlans: Set<Double> = []
    /// Smart plugs (devType 6) and CT meters (devType 2–4) attached to the station, by serial.
    private(set) var plugs: [String: SubDevice] = [:]
    private(set) var meters: [String: SubDevice] = [:]

    /// Planned outages of this station's queue per day ("yyyy-MM-dd" → spans), last version seen; for plan-vs-fact.
    var planLog: [String: [ScheduleChange.Span]] = [:]

    /// Charge limit raised by smart charging, to be restored after `until`.
    struct SmartChargeState: Codable, Equatable { var originalLimit: Int; var until: Double; var reason: String }
    var smartCharge: SmartChargeState?

    /// The last change of this station's queue schedule and when it was noticed.
    var lastScheduleChange: (at: Date, change: ScheduleChange)?

    /// Commands sent but not yet reflected by the station: key → (value, sent at).
    private(set) var pending: [String: (value: Int, sentAt: Date)] = [:]
    /// Last command the station didn't confirm in time.
    private(set) var failedCommand: String?

    init(config: StationConfig, tau: Double = 60) {
        self.config = config
        self.tau = tau
    }

    var sn: String { config.deviceSn }
    var name: String { config.displayName }

    func update(config c: StationConfig) {
        precondition(c.deviceSn == config.deviceSn)
        config = c
    }

    private static let meta: Set<String> = ["type", "eventId", "messageId", "ts", "deviceType", "token", "softver", "body"]

    enum Ingest { case ignored, data, tokenRejected }

    /// Feeds one decoded MQTT message addressed to this station.
    @discardableResult
    func ingest(_ json: [String: Any], at now: Date = Date()) -> Ingest {
        let type = json["type"] as? Int
        if type == 123 {
            if let b = json["body"] as? [String: Any], (b["errorCode"] as? Int) == 401 {
                tokenRejected = true
                return .tokenRejected
            }
            return .ignored
        }
        var body = json["body"] as? [String: Any]
        if body == nil { body = json.filter { !Self.meta.contains($0.key) } }
        guard let body, !body.isEmpty else { return .ignored }
        let hasLists = body["plugs"] != nil || body["plug"] != nil || body["cts"] != nil || body["ct"] != nil
        if type == 101 { return ingestSubDeviceLists(body, at: now) ? .data : .ignored }
        if hasLists { _ = ingestSubDeviceLists(body, at: now) }          // lists inside a station message
        if let bsn = body["deviceSn"] as? String, bsn != sn, bsn != "system" {     // one sub-device's update
            return updateSubDevice(bsn, body, at: now) ? .data : .ignored
        }

        if let v = json["softver"] as? String { softver = v }
        var got = false
        for (k, v) in body {
            if let d = Self.number(v) { values[k] = d; got = true }
        }
        if values["gridInPw"] == nil, let v = values["gridBuyPw"] { values["gridInPw"] = v }
        if values["gridOutPw"] == nil, let v = values["gridSellPw"] { values["gridOutPw"] = v }
        guard got else { return .ignored }
        tokenRejected = false
        lastUpdate = now
        sample(at: now)
        resolvePending(now: now)
        // Only messages that actually carry grid state count towards outage detection.
        if body["ongridStat"] != nil || body["gridInPw"] != nil || body["inOngridPw"] != nil {
            grid.update(gridPresent, at: now.timeIntervalSince1970)
        }
        return .data
    }

    static func number(_ v: Any) -> Double? {
        switch v {
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    // MARK: sub-devices

    private func ingestSubDeviceLists(_ body: [String: Any], at now: Date) -> Bool {
        var changed = false
        for key in ["plugs", "plug", "socket", "sockets"] {
            for item in (body[key] as? [[String: Any]]) ?? [] {
                guard let s = (item["deviceSn"] ?? item["sn"]) as? String, s != sn else { continue }
                var d = plugs[s] ?? SubDevice(sn: s, devType: 6)
                d.merge(item, at: now); plugs[s] = d; changed = true
            }
        }
        for key in ["cts", "ct"] {
            for item in (body[key] as? [[String: Any]]) ?? [] {
                guard let s = (item["deviceSn"] ?? item["sn"]) as? String, s != sn else { continue }
                var d = meters[s] ?? SubDevice(sn: s, devType: (item["devType"] as? Int) ?? 2)
                d.merge(item, at: now); meters[s] = d; changed = true
            }
        }
        return changed
    }

    private func updateSubDevice(_ s: String, _ body: [String: Any], at now: Date) -> Bool {
        if var d = plugs[s] { d.merge(body, at: now); plugs[s] = d; return true }
        if var d = meters[s] { d.merge(body, at: now); meters[s] = d; return true }
        let dt = body["devType"] as? Int
        if dt == 6 || ["switchSta", "sysSwitch", "outPw", "totalEgy"].contains(where: { body[$0] != nil }) {
            var d = SubDevice(sn: s, devType: 6); d.merge(body, at: now); plugs[s] = d; return true
        }
        if [2, 3, 4].contains(dt ?? -1) || ["aPhasePw", "AphasePw", "tPhasePw", "TphasePw", "subType"].contains(where: { body[$0] != nil }) {
            var d = SubDevice(sn: s, devType: dt ?? 3); d.merge(body, at: now); meters[s] = d; return true
        }
        return false
    }

    /// Marks a plug switch command as sent (shown as pending until the plug reports the new state).
    func markPlugSent(_ s: String, on: Bool, at now: Date = Date()) {
        plugs[s]?.pendingOn = on
        plugs[s]?.pendingAt = now
    }

    // MARK: smoothing & sampling

    private func sample(at now: Date) {
        guard let net = rawNet else { return }
        let dt = lastSample.map { now.timeIntervalSince($0) } ?? 0
        smoothedNet = Self.ema(smoothedNet, net, dt: dt, tau: tau)
        let load = rawLoad
        if let load { smoothedLoad = Self.ema(smoothedLoad, load, dt: dt, tau: tau) }
        lastSample = now
        // Learn inverter losses only when the battery alone feeds the outputs.
        if let load, let out = v("batOutPw"), (v("batInPw") ?? 0) < 5, (v("pvPw") ?? 0) < 5,
           (v("swEpsInPw") ?? 0) < 5, (v("inOngridPw") ?? 0) < 5 {
            loss.add(output: load, battery: out, at: now)
        }
        if (v("pvPw") ?? 0) > 0 { pvSeen = true }
        store.record(at: now, values: metricValues())
    }

    static func ema(_ prev: Double?, _ x: Double, dt: Double, tau: Double) -> Double {
        guard let s = prev, dt > 0 else { return x }
        // Snap immediately when direction flips or the value jumps a lot.
        if (s > 20 && x < -20) || (s < -20 && x > 20) || abs(x - s) > max(300, abs(s)) { return x }
        return s + (x - s) * (1 - exp(-dt / tau))
    }

    // MARK: derived values

    func v(_ k: String) -> Double? { values[k] }

    var soc: Double? { v("soc") ?? v("batSoc") }

    /// Net battery power, + = charging, − = discharging (official app formula).
    var rawNet: Double? {
        if v("batInPw") != nil || v("batOutPw") != nil {
            return (v("batInPw") ?? 0) - (v("batOutPw") ?? 0)
        }
        let pv = v("pvPw") ?? 0
        let ac = (v("swEpsInPw") ?? 0) - (v("swEpsOutPw") ?? 0)
        var ong: Double?
        for (i, o) in [("gridInPw", "gridOutPw"), ("inOngridPw", "outOngridPw"), ("inGridSidePw", "outGridSidePw")] {
            if v(i) != nil || v(o) != nil {
                let x = (v(i) ?? 0) - (v(o) ?? 0)
                if ong == nil || abs(x) > abs(ong!) { ong = x }
            }
        }
        if ong == nil && v("pvPw") == nil && v("swEpsInPw") == nil && v("swEpsOutPw") == nil { return nil }
        return pv + ac + (ong ?? 0)
    }

    /// What the station delivers to consumers right now, W: AC socket (EPS) + grid port output.
    var rawLoad: Double? {
        let eps = v("swEpsOutPw"), ong = v("outOngridPw")
        if eps == nil && ong == nil { return nil }
        return (eps ?? 0) + (ong ?? 0)
    }

    /// Net grid-port power, + from grid / − to grid.
    var gridNet: Double? {
        let gi = v("gridInPw") ?? v("inOngridPw"), go = v("gridOutPw") ?? v("outOngridPw")
        guard gi != nil || go != nil else { return nil }
        return (gi ?? 0) - (go ?? 0)
    }

    /// Is mains power present? From the station's own `ongridStat` (1 = on-grid, 0 = off-grid);
    /// if a firmware doesn't send it, power drawn from the grid also proves it's there.
    /// "0 W from grid" alone is NOT treated as an outage — the station may just not be using it.
    var gridPresent: Bool? {
        if let s = v("ongridStat") { return s >= 1 }
        if let g = gridNet, g > 5 { return true }
        return nil
    }

    var capacityWh: Double {
        if let c = config.capacityWh { return c }
        // batNum counts expansion packs only (a bare head unit reports 0).
        return (config.moduleWh ?? 2520) * (1 + max(0, v("batNum") ?? 0))
    }

    var minSoc: Double { v("socDischgLimit") ?? 0 }
    var maxSoc: Double { min(100, v("socChgLimit") ?? 100) }

    var isStale: Bool {
        guard let u = lastUpdate else { return true }
        return Date().timeIntervalSince(u) > 90
    }

    var isCharging: Bool { (smoothedNet ?? 0) >= 15 }
    var isDischarging: Bool { (smoothedNet ?? 0) <= -15 }

    var usableWh: Double? { soc.map { max(0, $0 - minSoc) / 100 * capacityWh } }

    /// Hours the battery lasts at the current consumption.
    /// Discharging: measured battery output. Otherwise: output load converted to battery draw
    /// through the learned loss model (inverter losses + station's own consumption).
    var runtimeHours: Double? {
        guard let wh = usableWh else { return nil }
        if isDischarging, let net = smoothedNet { return wh / -net }
        guard let draw = batteryDraw else { return nil }
        return draw < 5 ? .infinity : wh / draw
    }

    /// Battery power the current load costs (measured while discharging, estimated otherwise).
    var batteryDraw: Double? {
        if isDischarging, let net = smoothedNet { return -net }
        return smoothedLoad.map { loss.batteryDraw(output: $0) }
    }

    var toFullHours: Double? {
        guard isCharging, let soc, let net = smoothedNet else { return nil }
        return max(0, maxSoc - soc) / 100 * capacityWh / net
    }

    var cellTempC: Double? { v("cellTemp").map { $0 > 100 ? $0 / 10 : $0 } }
    var minCellTempC: Double? { v("minCellTemp").map { $0 > 100 ? $0 / 10 : $0 } }
    var maxCellTempC: Double? { v("maxCellTemp").map { $0 > 100 ? $0 / 10 : $0 } }

    // MARK: metrics

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

    /// Current value shown on the metric page.
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

    // MARK: outages

    /// One-minute series for an outage, built from the 24 h history.
    func buildSeries(for o: GridLog.Outage, now: Double = Date().timeIntervalSince1970) -> OutageSeries? {
        let end = o.end ?? now
        let n = Int(ceil((end - o.start) / 60))
        guard n > 0 else { return nil }
        let to = o.start + Double(n) * 60
        func col(_ c: String) -> [Double?] { store.raw.buckets(c, from: o.start, to: to, count: n) { $0 } }
        return OutageSeries(t0: o.start, step: 60, ac: col("ac"), bat: col("battery"), soc: col("soc"), temp: col("temp"))
    }

    /// Series for display: fresh from history while it still covers the outage, otherwise the saved copy.
    func series(for o: GridLog.Outage) -> OutageSeries? {
        let now = Date().timeIntervalSince1970
        if (o.end ?? now) > now - MetricStore.rawRetention + 300, let s = buildSeries(for: o), s.ac.contains(where: { $0 != nil }) {
            return s
        }
        return o.series
    }

    /// Stores series snapshots for outages the history still covers (called with every save).
    func snapshotOutages() {
        let now = Date().timeIntervalSince1970
        for o in grid.outages where (o.end ?? now) > now - MetricStore.rawRetention + 300 {
            if let s = buildSeries(for: o), s.ac.contains(where: { $0 != nil }) {
                grid.setSeries(s, forStart: o.start)
            }
        }
    }

    // MARK: commands

    func markSent(_ c: JackeryProtocol.Command, at now: Date = Date()) {
        guard c != .reboot else { return }
        pending[c.key] = (c.value, now)
        failedCommand = nil
    }

    /// A pending command is done once the station reports the new value; it fails after 30 s.
    private func resolvePending(now: Date) {
        for (key, p) in pending {
            if let v = values[key], Int(v.rounded()) == p.value {
                pending[key] = nil
            } else if now.timeIntervalSince(p.sentAt) > 30 {
                pending[key] = nil
                failedCommand = key
            }
        }
    }

    func isPending(_ key: String) -> Bool { pending[key] != nil }

    // MARK: persistence

    func save() {
        store.save(raw: Paths.file(.metrics, sn), long: Paths.file(.longterm, sn))
        if let d = try? JSONEncoder().encode(planLog) { try? d.write(to: Paths.file(.plans, sn), options: .atomic) }
        if let s = smartCharge, let d = try? JSONEncoder().encode(s) { try? d.write(to: Paths.file(.smartcharge, sn), options: .atomic) }
        else { try? FileManager.default.removeItem(at: Paths.file(.smartcharge, sn)) }
        snapshotOutages()
        grid.save(to: Paths.file(.outages, sn))
        loss.save(to: Paths.file(.losses, sn))
    }

    func load() {
        store.load(raw: Paths.file(.metrics, sn), long: Paths.file(.longterm, sn))
        if let d = try? Data(contentsOf: Paths.file(.plans, sn)), let p = try? JSONDecoder().decode([String: [ScheduleChange.Span]].self, from: d) { planLog = p }
        if let d = try? Data(contentsOf: Paths.file(.smartcharge, sn)) { smartCharge = try? JSONDecoder().decode(SmartChargeState.self, from: d) }
        grid.load(from: Paths.file(.outages, sn))
        loss.load(from: Paths.file(.losses, sn))
    }

    /// Forgets all history (the live state stays).
    func clearHistory() {
        store.removeAll()
        grid.removeAll()
        loss.reset()
        lowBattery = LowBatteryTracker()
        planLog = [:]
    }

    // MARK: previews & tests

    /// Injects a ready state (used by screenshot rendering and tests).
    func inject(values: [String: Double], net: Double?, load: Double?, at now: Date = Date()) {
        self.values = values
        smoothedNet = net
        smoothedLoad = load
        lastUpdate = now
        lastSample = now
        if (values["pvPw"] ?? 0) > 0 { pvSeen = true }
    }
}

/// Fires once per threshold while the battery is discharging; re-arms after recharging 5 % above it.
struct LowBatteryTracker {
    private(set) var fired: Set<Int> = []

    /// Returns the threshold to notify about, if any.
    mutating func check(soc: Double, discharging: Bool, thresholds: [Int]) -> Int? {
        fired = fired.filter { soc <= Double($0) + 5 }
        guard discharging else { return nil }
        let crossed = thresholds.filter { soc <= Double($0) && !fired.contains($0) }
        guard let lowest = crossed.min() else { return nil }
        fired.formUnion(crossed)
        return lowest
    }
}

/// A smart plug or CT meter reported by the station.
struct SubDevice: Equatable {
    var sn: String
    var devType: Int
    var name: String?
    var values: [String: Double] = [:]
    var commMode: Int?
    var commState: Int?
    var lastSeen: Date?
    var pendingOn: Bool?
    var pendingAt: Date?

    var isPlug: Bool { devType == 6 }
    var displayName: String { (name?.isEmpty == false ? name : nil) ?? String(sn.suffix(6)) }
    /// Plugs can be switched over MQTT only in local mode (commMode 1); cloud plugs only from the Jackery app.
    var isLocal: Bool { commMode == 1 }
    var isOn: Bool? { (values["switchSta"] ?? values["sysSwitch"]).map { $0 >= 1 } }
    var online: Bool { commState.map { $0 == 1 } ?? true }

    /// Plug power, W.
    var power: Double? { values["outPw"] ?? values["power"] }
    /// CT: power from the grid (+) / to the grid (−), W — total or the sum of phases.
    var gridPower: Double? {
        let fwd = values["tPhasePw"] ?? values["TphasePw"] ?? sum(["aPhasePw", "bPhasePw", "cPhasePw", "AphasePw", "BphasePw", "CphasePw"])
        let rev = values["tnPhasePw"] ?? values["TnphasePw"] ?? sum(["anPhasePw", "bnPhasePw", "cnPhasePw", "AnphasePw", "BnphasePw", "CnphasePw"])
        guard fwd != nil || rev != nil else { return nil }
        return (fwd ?? 0) - (rev ?? 0)
    }
    var energyKWh: Double? { values["totalEgy"] ?? values["egy"] }

    private func sum(_ keys: [String]) -> Double? {
        let v = keys.compactMap { values[$0] }
        return v.isEmpty ? nil : v.reduce(0, +)
    }

    mutating func merge(_ item: [String: Any], at now: Date) {
        if let n = (item["name"] ?? item["scanName"]) as? String, !n.isEmpty { name = n }
        if let dt = item["devType"] as? Int { devType = dt }
        for (k, v) in item { if let d = Station.number(v) { values[k] = d } }
        commMode = values["commMode"].map(Int.init) ?? commMode
        commState = values["commState"].map(Int.init) ?? commState
        lastSeen = now
        if let p = pendingOn, isOn == p { pendingOn = nil; pendingAt = nil }
        if let at = pendingAt, now.timeIntervalSince(at) > 30 { pendingOn = nil; pendingAt = nil }
    }
}
