// JackeryBar — menu bar widget for Jackery SolarVault 3 (local MQTT protocol).
// Shows state of charge and estimated runtime at the current load.

import Cocoa
import Network
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Config

struct Config: Codable {
    var host: String
    var port: Int?
    var username: String?
    var password: String?
    var deviceSn: String
    var token: String
    var topicPrefix: String?
    /// Total usable capacity in Wh. If nil: moduleWh × batNum reported by the device.
    var capacityWh: Double?
    /// Capacity of one battery module in Wh (SolarVault 3 Pro Max / Pro Max AC: 2520).
    var moduleWh: Double?
    /// Window of power smoothing for the runtime estimate, seconds.
    var smoothingSeconds: Double?
    /// Popup theme: "dark" (default), "light" or "system".
    var theme: String?
    /// UI language: "uk" (default) or "en".
    var language: String?
    /// Title shown in the popup (default "Jackery SolarVault 3").
    var name: String?

    static let url: URL = {
        if let i = CommandLine.arguments.firstIndex(of: "--config"), i + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/jackery-bar/config.json")
    }()
    static var dir: URL { url.deletingLastPathComponent() }

    static let template = """
    {
      "host": "192.168.1.10",
      "port": 1883,
      "username": "",
      "password": "",
      "deviceSn": "СЕРИЙНЫЙ_НОМЕР_СТАНЦИИ",
      "token": "ТОКЕН_ИЗ_ПРИЛОЖЕНИЯ_JACKERY",
      "topicPrefix": "hb",
      "moduleWh": 2520
    }

    """

    static func load() -> Config? {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data),
              !cfg.deviceSn.contains("СЕРИЙНЫЙ"), !cfg.token.contains("ТОКЕН")
        else { return nil }
        return cfg
    }
}

// MARK: - Minimal MQTT 3.1.1 client (QoS 0) over Network.framework

final class MQTTClient {
    var onMessage: ((String, Data) -> Void)?
    var onStatus: ((String?) -> Void)?   // nil = connected, otherwise error text

    private let cfg: Config
    private let topics: [String]
    private let queue = DispatchQueue(label: "jackerybar.mqtt")
    private var conn: NWConnection?
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var packetId: UInt16 = 1
    private var stopped = false

    init(cfg: Config, topics: [String]) {
        self.cfg = cfg
        self.topics = topics
    }

    func start() { queue.async { self.connect() } }

    func stop() {
        queue.async {
            self.stopped = true
            self.pingTimer?.cancel()
            self.conn?.cancel()
            self.conn = nil
        }
    }

    func publish(_ topic: String, _ payload: Data) {
        queue.async {
            var body = Self.str(topic)
            body.append(payload)
            self.send(Self.packet(0x30, body))
        }
    }

    // --- connection lifecycle

    private func connect() {
        guard !stopped else { return }
        buffer.removeAll()
        let port = NWEndpoint.Port(rawValue: UInt16(cfg.port ?? 1883)) ?? 1883
        let c = NWConnection(host: NWEndpoint.Host(cfg.host), port: port, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready:
                self.sendConnect()
                self.receive(on: c)
            case .waiting(let err), .failed(let err):
                self.drop(c, reason: L("Немає зв’язку з брокером: \(err.localizedDescription)", "Can’t reach the broker: \(err.localizedDescription)"))
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func drop(_ c: NWConnection, reason: String) {
        guard c === conn else { return }
        conn = nil
        pingTimer?.cancel()
        pingTimer = nil
        c.cancel()
        onStatus?(reason)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connect() }
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, done, err in
            guard let self, let c, c === self.conn else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parse()
            }
            if done || err != nil {
                self.drop(c, reason: L("Брокер закрив з’єднання", "Broker closed the connection"))
            } else {
                self.receive(on: c)
            }
        }
    }

    private func send(_ d: Data) {
        conn?.send(content: d, completion: .contentProcessed { _ in })
    }

    // --- packets

    private func sendConnect() {
        var flags: UInt8 = 0x02 // clean session
        var payload = Self.str("jackerybar-\(UUID().uuidString.prefix(8))")
        if let u = cfg.username, !u.isEmpty {
            flags |= 0x80
            payload.append(Self.str(u))
            if let p = cfg.password, !p.isEmpty {
                flags |= 0x40
                payload.append(Self.str(p))
            }
        }
        var body = Self.str("MQTT")
        body.append(contentsOf: [0x04, flags, 0x00, 30]) // level 4, keepalive 30 s
        body.append(payload)
        send(Self.packet(0x10, body))
    }

    private func subscribe() {
        for t in topics {
            packetId = packetId &+ 1
            if packetId == 0 { packetId = 1 }
            var body = Data([UInt8(packetId >> 8), UInt8(packetId & 0xff)])
            body.append(Self.str(t))
            body.append(0x00)
            send(Self.packet(0x82, body))
        }
    }

    private func startPing() {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in self?.send(Data([0xC0, 0x00])) }
        t.resume()
        pingTimer = t
    }

    private func parse() {
        while buffer.count >= 2 {
            var value = 0, mult = 1, idx = 1, complete = false
            while idx < buffer.count && idx <= 4 {
                let b = buffer[buffer.startIndex + idx]
                value += Int(b & 0x7f) * mult
                mult *= 128
                idx += 1
                if b & 0x80 == 0 { complete = true; break }
            }
            guard complete else { return }
            let total = idx + value
            guard buffer.count >= total else { return }
            let pkt = Data(buffer.prefix(total))
            buffer = Data(buffer.dropFirst(total))
            handle(header: pkt[0], body: pkt.subdata(in: idx..<total))
        }
    }

    private func handle(header: UInt8, body: Data) {
        switch header >> 4 {
        case 2: // CONNACK
            let code = body.count >= 2 ? body[1] : 255
            if code == 0 {
                subscribe()
                startPing()
                onStatus?(nil)
            } else {
                let why = [1: L("версія протоколу", "protocol version"), 2: "client id", 3: L("сервер недоступний", "server unavailable"),
                           4: L("логін/пароль", "username/password"), 5: L("немає авторизації", "not authorized")][Int(code)] ?? L("код \(code)", "code \(code)")
                if let c = conn { drop(c, reason: L("Брокер відмовив: \(why)", "Broker refused: \(why)")) }
            }
        case 3: // PUBLISH
            guard body.count >= 2 else { return }
            let qos = (header >> 1) & 0x03
            let tlen = Int(body[0]) << 8 | Int(body[1])
            guard body.count >= 2 + tlen else { return }
            let topic = String(decoding: body.subdata(in: 2..<(2 + tlen)), as: UTF8.self)
            var pos = 2 + tlen
            if qos > 0, body.count >= pos + 2 {
                if qos == 1 { send(Data([0x40, 0x02, body[pos], body[pos + 1]])) }
                pos += 2
            }
            onMessage?(topic, body.subdata(in: pos..<body.count))
        default:
            break // SUBACK, PINGRESP, …
        }
    }

    static func str(_ s: String) -> Data {
        let b = Data(s.utf8)
        var d = Data([UInt8(b.count >> 8), UInt8(b.count & 0xff)])
        d.append(b)
        return d
    }

    static func packet(_ type: UInt8, _ body: Data) -> Data {
        var d = Data([type])
        var len = body.count
        repeat {
            var byte = UInt8(len % 128)
            len /= 128
            if len > 0 { byte |= 0x80 }
            d.append(byte)
        } while len > 0
        d.append(body)
        return d
    }
}

// MARK: - Inverter loss model

/// Learns how much the battery has to give for a given AC output, from real discharge periods:
/// batteryDraw = slope × outputW + intercept, where `intercept` is the station's own consumption.
/// Used to estimate runtime while the station is charging (when the battery isn't feeding the load).
final class LossModel {
    private(set) var pairs: [[Double]] = []   // [outputW, batteryW]
    private var lastAdd: Date?
    private(set) var slope = 1 / 0.9          // default ~90 % until learned
    private(set) var intercept = 0.0
    private(set) var isLinear = false

    var isLearned: Bool { pairs.count >= 6 }

    func add(output: Double, battery: Double, at t: Date = Date()) {
        guard output >= 10, battery >= 30 else { return }
        let r = battery / output
        guard r >= 0.95, r <= 1.8 else { return }          // mismatched/transitional readings
        if let l = lastAdd, t.timeIntervalSince(l) < 20 { return }
        lastAdd = t
        pairs.append([output, battery])
        if pairs.count > 400 { pairs.removeFirst(pairs.count - 400) }
        fit()
    }

    private func fit() {
        guard pairs.count >= 6 else { return }
        let n = Double(pairs.count)
        let xs = pairs.map { $0[0] }, ys = pairs.map { $0[1] }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) } / n
        // Need a real spread of loads to separate fixed and proportional losses.
        if sxx > 40 * 40 {
            let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / n
            let a = sxy / sxx, b = my - a * mx
            if (1.0...1.4).contains(a), (0...80).contains(b) {
                slope = a; intercept = b; isLinear = true
                return
            }
        }
        slope = min(1.6, max(1.0, my / mx)); intercept = 0; isLinear = false
    }

    /// Battery power needed to deliver `output` watts.
    func batteryDraw(output: Double) -> Double { output < 1 ? intercept : slope * output + intercept }

    /// Efficiency (output / battery) at the given output.
    func efficiency(output: Double) -> Double? {
        let d = batteryDraw(output: output)
        return d > 0 && output >= 1 ? output / d : nil
    }

    func load(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([[Double]].self, from: data) else { return }
        pairs = rows.filter { $0.count == 2 }.suffix(400).map { $0 }
        fit()
    }

    func save(to url: URL) {
        guard !pairs.isEmpty, let data = try? JSONEncoder().encode(pairs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Station state

final class Station {
    private(set) var values: [String: Double] = [:]
    private(set) var lastUpdate: Date?
    private(set) var smoothedNet: Double?   // W, + charging / − discharging
    private var lastSample: Date?
    var model: String?
    var softver: String?

    let sn: String
    let capacityOverride: Double?
    let moduleWh: Double
    let tau: Double

    init(sn: String, capacityOverride: Double?, moduleWh: Double, tau: Double) {
        self.sn = sn
        self.capacityOverride = capacityOverride
        self.moduleWh = moduleWh
        self.tau = tau
    }

    private static let meta: Set<String> = ["type", "eventId", "messageId", "ts", "deviceType", "token", "softver", "body"]

    /// Returns true if the message carried data for the head unit.
    @discardableResult
    func ingest(_ json: [String: Any]) -> Bool {
        let type = json["type"] as? Int
        if type == 101 { return false }                 // sub-device lists
        var body = json["body"] as? [String: Any]
        if body == nil { body = json.filter { !Self.meta.contains($0.key) } }
        guard let body, !body.isEmpty else { return false }
        if let bsn = body["deviceSn"] as? String, bsn != sn, bsn != "system" { return false } // CT / plugs

        if let v = json["softver"] as? String { softver = v }
        var got = false
        for (k, v) in body {
            if let d = Self.number(v) { values[k] = d; got = true }
        }
        if values["gridInPw"] == nil, let v = values["gridBuyPw"] { values["gridInPw"] = v }
        if values["gridOutPw"] == nil, let v = values["gridSellPw"] { values["gridOutPw"] = v }
        guard got else { return false }
        lastUpdate = Date()
        sampleNet()
        // Only messages that actually carry grid state count towards outage detection.
        if body["ongridStat"] != nil || body["gridInPw"] != nil || body["inOngridPw"] != nil {
            grid.update(gridPresent)
        }
        return true
    }

    /// Fills the station with a plausible scenario for screenshots: charged from the grid,
    /// then a power outage that is still going on, plus a week of past outages.
    func seedPreview() {
        let now = Date()
        var soc = 50.0
        for i in 0..<1440 {
            let ts = -7200 + Double(i) * 5
            let vals: [String: Double]
            if ts < -4300 {
                soc = min(82, soc + 900 * 5 / 3600 / 2520 * 100)
                vals = ["battery": 900, "grid": 983, "ac": 83, "soc": soc, "temp": 27, "wifi": -41]
            } else {
                let x = (ts + 4300) / 4300
                let load = 380 + 160 * sin(x * 9) + (x > 0.55 && x < 0.62 ? 700 : 0)
                let bat = -(load * 1.08 + 22)
                soc += bat * 5 / 3600 / 2520 * 100
                vals = ["battery": bat, "grid": 0, "ac": load, "soc": soc, "temp": 27 + 3 * x, "wifi": -41]
                if i % 5 == 0 { loss.add(output: load, battery: -bat, at: now.addingTimeInterval(ts)) }
            }
            store.record(at: now.addingTimeInterval(ts), values: vals)
        }
        let load = 440.0
        values = ["soc": soc, "batNum": 0, "socDischgLimit": 10, "socChgLimit": 100, "batInPw": 0,
                  "batOutPw": load * 1.08 + 22, "gridInPw": 0, "gridOutPw": 0, "ongridStat": 0,
                  "swEpsInPw": 0, "swEpsOutPw": load, "pvPw": 0,
                  "cellTemp": 297, "minCellTemp": 284, "maxCellTemp": 301, "wsig": -41]
        let d = 86400.0, n0 = now.timeIntervalSince1970
        for (s, e) in [(n0 - 6 * d + 3600 * 9, n0 - 6 * d + 3600 * 13), (n0 - 4 * d + 3600 * 18, n0 - 4 * d + 3600 * 22),
                       (n0 - 2 * d + 3600 * 5, n0 - 2 * d + 3600 * 9), (n0 - d + 3600 * 14, n0 - d + 3600 * 16.5)] {
            grid.update(false, at: s); grid.update(false, at: s); grid.update(true, at: e); grid.update(true, at: e)
        }
        grid.update(false, at: n0 - 4300); grid.update(false, at: n0 - 4300)
        smoothedNet = -(load * 1.08 + 22); smoothedLoad = load
        lastUpdate = now.addingTimeInterval(-2); lastSample = now
    }

    func demoTick() {
        let t = Date().timeIntervalSince1970
        values["soc"] = 73
        values["batNum"] = 2
        values["socDischgLimit"] = 10
        values["socChgLimit"] = 100
        values["batInPw"] = 0
        values["batOutPw"] = 410 + 40 * sin(t / 7)
        values["otherLoadPw"] = 410 + 40 * sin(t / 7)
        values["swEpsOutPw"] = 120
        lastUpdate = Date()
        sampleNet()
    }

    private func sampleNet() {
        guard let net = rawNet else { return }
        let now = Date()
        let dt = lastSample.map { now.timeIntervalSince($0) } ?? 0
        smoothedNet = Self.ema(smoothedNet, net, dt: dt, tau: tau)
        let load = rawLoad()
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

    private static func ema(_ prev: Double?, _ x: Double, dt: Double, tau: Double) -> Double {
        guard let s = prev, dt > 0 else { return x }
        // Snap immediately when direction flips or the value jumps a lot.
        if (s > 20 && x < -20) || (s < -20 && x > 20) || abs(x - s) > max(300, abs(s)) { return x }
        return s + (x - s) * (1 - exp(-dt / tau))
    }

    /// What the station delivers to consumers right now, W: AC socket (EPS) + grid port output.
    private func rawLoad() -> Double? {
        let eps = v("swEpsOutPw"), ong = v("outOngridPw")
        if eps == nil && ong == nil { return nil }
        return (eps ?? 0) + (ong ?? 0)
    }

    private(set) var smoothedLoad: Double?
    let loss = LossModel()

    /// History of every metric (24 h), persisted as JSON.
    let store = MetricStore()
    /// Mains presence and the outage log.
    let grid = GridLog()

    /// True once the station reported PV power (AC-only models never do).
    private(set) var pvSeen = false

    static func number(_ v: Any) -> Double? {
        switch v {
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

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

    var capacityWh: Double {
        if let c = capacityOverride { return c }
        // batNum counts expansion packs only (a bare head unit reports 0).
        return moduleWh * (1 + max(0, v("batNum") ?? 0))
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

    /// Hours the battery lasts at the current consumption (∞ when nothing is drawn).
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
}

// MARK: - Formatting

enum Fmt {
    static func duration(_ h: Double) -> String {
        guard h.isFinite else { return "∞" }
        let mins = Int((h * 60).rounded())
        if mins < 60 { return L("\(max(mins, 1)) хв", "\(max(mins, 1))m") }
        if mins < 24 * 60 {
            let hh = mins / 60, mm = mins % 60
            return hh >= 10 || mm == 0 ? L("\(hh) год", "\(hh)h") : L("\(hh) год \(mm) хв", "\(hh)h \(mm)m")
        }
        let d = mins / (24 * 60), hh = (mins % (24 * 60)) / 60
        return d >= 7 ? L(">7 дн", ">7d") : (hh == 0 ? L("\(d) дн", "\(d)d") : L("\(d) дн \(hh) год", "\(d)d \(hh)h"))
    }

    /// Compact duration for the menu bar: "3г 40хв" / "3h 40m".
    static func durationShort(_ h: Double) -> String {
        guard h.isFinite else { return "∞" }
        let mins = Int((h * 60).rounded())
        if mins < 60 { return L("\(max(mins, 1))хв", "\(max(mins, 1))m") }
        if mins < 24 * 60 {
            let hh = mins / 60, mm = mins % 60
            return hh >= 10 || mm == 0 ? L("\(hh)г", "\(hh)h") : L("\(hh)г \(mm)хв", "\(hh)h \(mm)m")
        }
        let d = mins / (24 * 60)
        return d >= 7 ? L(">7д", ">7d") : L("\(d)д \((mins % (24 * 60)) / 60)г", "\(d)d \((mins % (24 * 60)) / 60)h")
    }

    static func watts(_ w: Double?) -> String {
        guard let w else { return "—" }
        return abs(w) >= 1000 ? String(format: L("%.2f кВт", "%.2f kW"), w / 1000) : L("\(Int(w.rounded())) Вт", "\(Int(w.rounded())) W")
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return L("ніколи", "never") }
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return L("\(s) с тому", "\(s) s ago") }
        if s < 3600 { return L("\(s / 60) хв тому", "\(s / 60) min ago") }
        return L("\(s / 3600) год тому", "\(s / 3600) h ago")
    }
}

// MARK: - Status item rendering (Stats "mini" look: small caption above a big value)

enum Renderer {
    static let captionFont = NSFont.systemFont(ofSize: 8.5, weight: .regular)
    static let valueFont = NSFont.systemFont(ofSize: 14, weight: .regular)

    struct Column { let caption: String; let value: String }

    static func image(soc: Double?, charging: Bool, columns: [Column], dimmed: Bool, height: CGFloat) -> NSImage {
        let pad: CGFloat = 3, iconW: CGFloat = 13, gap: CGFloat = 7
        let widths = columns.map { col -> CGFloat in
            let a = (col.caption as NSString).size(withAttributes: [.font: captionFont]).width
            let b = (col.value as NSString).size(withAttributes: [.font: valueFont]).width
            return ceil(max(a, b))
        }
        let width = pad + iconW + gap + widths.reduce(0, +) + gap * CGFloat(max(0, columns.count - 1)) + pad
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let alpha: CGFloat = dimmed ? 0.45 : 1
            let color = NSColor.black.withAlphaComponent(alpha)
            drawBattery(in: NSRect(x: pad, y: (height - 20) / 2, width: iconW, height: 20),
                        soc: soc, charging: charging, color: color)
            var x = pad + iconW + gap
            for (i, col) in columns.enumerated() {
                let w = widths[i]
                let cap = NSAttributedString(string: col.caption, attributes: [.font: captionFont, .foregroundColor: color])
                let val = NSAttributedString(string: col.value, attributes: [.font: valueFont, .foregroundColor: color])
                let cs = cap.size(), vs = val.size()
                // Stack: caption on top, value under it, centred vertically as a block.
                let block = cs.height + vs.height - 5
                let top = (height + block) / 2 + 0.5
                cap.draw(at: NSPoint(x: x, y: top - cs.height + 1))
                val.draw(at: NSPoint(x: x, y: top - cs.height - vs.height + 4))
                x += w + gap
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func drawBattery(in r: NSRect, soc: Double?, charging: Bool, color: NSColor) {
        color.set()
        let capH: CGFloat = 2
        let body = NSRect(x: r.minX + 0.75, y: r.minY + 0.75, width: r.width - 1.5, height: r.height - capH - 1.5)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1.5
        outline.stroke()
        NSBezierPath(roundedRect: NSRect(x: r.midX - 2.5, y: body.maxY + 0.5, width: 5, height: capH),
                     xRadius: 0.8, yRadius: 0.8).fill()

        let inner = body.insetBy(dx: 2, dy: 2)
        let level = CGFloat(min(100, max(0, soc ?? 0)) / 100)
        if level > 0 {
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: max(1.5, inner.height * level)),
                         xRadius: 1, yRadius: 1).fill()
        }
        if charging {
            // Punch a bolt out of the fill so it reads in template mode.
            let b = NSBezierPath()
            let cx = body.midX, cy = body.midY
            b.move(to: NSPoint(x: cx + 1.2, y: cy + 5.5))
            b.line(to: NSPoint(x: cx - 3.0, y: cy - 0.5))
            b.line(to: NSPoint(x: cx - 0.2, y: cy - 0.5))
            b.line(to: NSPoint(x: cx - 1.2, y: cy - 5.5))
            b.line(to: NSPoint(x: cx + 3.0, y: cy + 0.5))
            b.line(to: NSPoint(x: cx + 0.2, y: cy + 0.5))
            b.close()
            NSGraphicsContext.current?.compositingOperation = .xor
            b.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // Show banners even if the app happens to be frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // Clicking a notification opens the outage page.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.panel.showOutages = true
            if !self.popup.isVisible, let b = self.item.button { self.redraw(); self.popup.show(below: b) }
        }
        done()
    }

    private var item: NSStatusItem!
    private var cfg: Config?
    private var station: Station?
    private var mqtt: MQTTClient?
    private var pollTimer: Timer?
    private var redrawTimer: Timer?
    private var historyTimer: Timer?

    private func historyURL(_ sn: String) -> URL {
        Config.dir.appendingPathComponent("history-\(sn.filter { $0.isLetter || $0.isNumber }).json")
    }

    private func outagesURL(_ sn: String) -> URL {
        Config.dir.appendingPathComponent("outages-\(sn.filter { $0.isLetter || $0.isNumber }).json")
    }

    /// macOS notification when mains power goes away or comes back.
    private func notifyGrid(on: Bool, ended: GridLog.Outage?, st: Station) {
        let c = UNMutableNotificationContent()
        let soc = st.soc.map { "\(Int($0.rounded()))%" } ?? "—"
        if on {
            c.title = L("Світло з’явилося", "Power is back")
            c.body = (ended.map { L("Світла не було \(Fmt.span($0.duration)). ", "Outage lasted \(Fmt.span($0.duration)). ") } ?? "") + L("Заряд \(soc).", "Charge \(soc).")
        } else {
            c.title = L("Зникло світло", "Power outage")
            let rt = st.runtimeHours.map { $0.isFinite ? L(", вистачить на ~\(Fmt.duration($0))", ", lasts ~\(Fmt.duration($0))") : "" } ?? ""
            c.body = L("Станція на батареї: заряд \(soc)\(rt).", "Station on battery: \(soc)\(rt).")
        }
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func metricsURL(_ sn: String) -> URL {
        Config.dir.appendingPathComponent("metrics-\(sn.filter { $0.isLetter || $0.isNumber }).json")
    }

    private func lossURL(_ sn: String) -> URL {
        Config.dir.appendingPathComponent("losses-\(sn.filter { $0.isLetter || $0.isNumber }).json")
    }

    private func saveHistory() {
        guard !demo, let st = station else { return }
        st.store.save(to: metricsURL(st.sn))
        st.snapshotOutages()
        st.grid.save(to: outagesURL(st.sn))
        st.loss.save(to: lossURL(st.sn))
    }

    func applicationWillTerminate(_ n: Notification) { saveHistory() }

    /// SIGTERM (pkill, logout, reinstall) goes through a normal terminate so history gets saved.
    private var sigterm: DispatchSourceSignal?
    private func handleSigterm() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }
    private var connError: String? = L("Підключення…", "Connecting…")
    private let demo = CommandLine.arguments.contains("--demo")
    private lazy var popup = PopupWindow(root: PanelView(model: panel))
    private let panel = PanelModel()

    func applicationDidFinishLaunching(_ n: Notification) {
        handleSigterm()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        panel.demo = demo
        panel.onOpenConfig = { [weak self] in self?.popup.close(); self?.openConfig() }
        panel.onReload = { [weak self] in self?.reload() }
        popup.onEscape = { [weak self] in
            guard let self else { return false }
            if self.panel.showSettings { self.panel.closeSettings(); return true }
            if self.panel.detail != nil { self.panel.detail = nil; return true }
            if self.panel.outageStart != nil { self.panel.outageStart = nil; return true }
            if self.panel.showOutages { self.panel.showOutages = false; return true }
            return false
        }
        installEditMenu()
        panel.onLayoutChange = { [weak self] in
            guard let self, self.popup.isVisible else { return }
            self.popup.fitToContent()
        }
        panel.onLanguage = { [weak self] lang in
            guard let self, lang != Lang.current else { return }
            Lang.current = lang
            // Remember it; the rest of config.json stays untouched.
            if var c = Config.loadRaw() { c.language = lang.rawValue; try? c.save() }
            self.panel.draft.language = lang.rawValue
            self.redraw()
        }
        panel.onSave = { [weak self] cfg in
            do { try cfg.save() } catch { return L("Не вдалося зберегти: \(error.localizedDescription)", "Couldn’t save: \(error.localizedDescription)") }
            self?.start()
            return nil
        }
        start()
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.togglePopover() }
        }
        redrawTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.redraw() }
    }

    private func start() {
        saveHistory()   // keep the old station's data before replacing it
        mqtt?.stop()
        mqtt = nil
        pollTimer?.invalidate()

        if demo {
            let st = Station(sn: "DEMO", capacityOverride: nil, moduleWh: 2520, tau: 60)
            station = st
            connError = nil
            st.demoTick()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in st.demoTick() }
            redraw()
            return
        }

        cfg = Config.load()
        popup.theme = cfg?.theme ?? "dark"
        panel.stationName = cfg?.name ?? Config.loadRaw()?.name ?? "Jackery SolarVault 3"
        Lang.current = Lang(rawValue: cfg?.language ?? Config.loadRaw()?.language ?? "uk") ?? .uk
        guard let cfg else { station = nil; redraw(); return }
        let st = Station(sn: cfg.deviceSn, capacityOverride: cfg.capacityWh,
                         moduleWh: cfg.moduleWh ?? 2520, tau: cfg.smoothingSeconds ?? 60)
        if !st.store.load(from: metricsURL(cfg.deviceSn)) {
            // First run with per-metric history: bring over the old battery-only chart.
            st.store.importLegacy(from: historyURL(cfg.deviceSn))
        }
        st.grid.load(from: outagesURL(cfg.deviceSn))
        st.grid.onChange = { [weak self, weak st] on, ended in
            guard let self, let st else { return }
            st.snapshotOutages()
            st.grid.save(to: self.outagesURL(st.sn))
            self.notifyGrid(on: on, ended: ended, st: st)
            self.redraw()
        }
        st.loss.load(from: lossURL(cfg.deviceSn))
        station = st
        historyTimer?.invalidate()
        historyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.saveHistory() }
        let prefix = cfg.topicPrefix ?? "hb"
        let base = "\(prefix)/device/\(cfg.deviceSn)"
        let client = MQTTClient(cfg: cfg, topics: ["\(base)/status", "\(base)/event"])
        client.onMessage = { [weak self] _, payload in
            guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }
            DispatchQueue.main.async {
                if st.ingest(json) { self?.redraw() }
            }
        }
        client.onStatus = { [weak self] err in
            DispatchQueue.main.async {
                self?.connError = err
                if err == nil { self?.poll() }
                self?.redraw()
            }
        }
        mqtt = client
        client.start()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        redraw()
    }

    private func poll() {
        guard let cfg, let mqtt, connError == nil else { return }
        let topic = "\(cfg.topicPrefix ?? "hb")/device/\(cfg.deviceSn)/action"
        let ts = Int(Date().timeIntervalSince1970)
        for type in [25, 105] { // device status + system full data (batInPw/batOutPw, soc, limits)
            let msg: [String: Any] = ["type": type, "eventId": 0, "messageId": Int.random(in: 1000...9999),
                                      "ts": ts, "token": cfg.token, "body": NSNull()]
            if let d = try? JSONSerialization.data(withJSONObject: msg) { mqtt.publish(topic, d) }
        }
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popup.isVisible {
            popup.close()
        } else {
            panel.closeSettings()
            panel.detail = nil
            panel.showOutages = false
            panel.outageStart = nil
            redraw()
            popup.show(below: button)
        }
    }

    private func redraw() {
        panel.station = station
        panel.connError = connError
        panel.tick &+= 1
        if popup.isVisible { DispatchQueue.main.async { self.popup.fitToContent() } }
        guard let button = item.button else { return }
        let h = NSStatusBar.system.thickness
        guard let st = station else {
            button.image = Renderer.image(soc: nil, charging: false,
                                          columns: [.init(caption: "JACKERY", value: L("налаштувати", "set up"))], dimmed: true, height: h)
            return
        }
        let soc = st.soc
        let socText = soc.map { "\(Int($0.rounded()))%" } ?? "—"
        // Discharging/idle: how long the battery lasts. Charging: how long until it's full.
        let charging = st.isCharging
        let caption = charging ? L("ДО \(Int(st.maxSoc))%", "TO \(Int(st.maxSoc))%") : st.grid.isOn == false ? L("БЕЗ СВІТЛА", "OUTAGE") : L("ЗАПАС", "LEFT")
        let value = charging
            ? (st.toFullHours.map { $0 < 1.0 / 60 ? L("повна", "full") : "~" + Fmt.durationShort($0) } ?? "—")
            : (st.runtimeHours.map { $0.isFinite ? "~" + Fmt.durationShort($0) : "∞" } ?? "—")
        button.image = Renderer.image(soc: soc, charging: charging,
                                      columns: [.init(caption: L("ЗАРЯД", "CHARGE"), value: socText), .init(caption: caption, value: value)],
                                      dimmed: st.isStale || connError != nil, height: h)
        button.toolTip = "Jackery SolarVault · \(socText) · \(value)"
        if CommandLine.arguments.contains("--debug") {
            FileHandle.standardError.write("[redraw] err=\(connError ?? "-") soc=\(socText) \(caption)=\(value) net=\(st.smoothedNet.map { String(Int($0)) } ?? "-") load=\(st.smoothedLoad.map { String(Int($0)) } ?? "-") cap=\(Int(st.capacityWh))\n".data(using: .utf8)!)
        }
    }

    /// Hidden main menu so ⌘X/⌘C/⌘V/⌘A/⌘Z work in the settings text fields.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L("Редагування", "Edit"))
        edit.addItem(withTitle: L("Скасувати", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Повторити", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Вирізати", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Копіювати", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Вставити", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Виділити все", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Config.url.path) { _ = Config.load() }
        NSWorkspace.shared.open(Config.url)
    }

    @objc private func reload() { start() }

}

// MARK: - Entry

if CommandLine.arguments.contains("--register-login") {
    do { try SMAppService.mainApp.register(); print("login item:", SMAppService.mainApp.status.rawValue) }
    catch { print("login item error:", error) }
    exit(0)
}

// `--render-panel <file.png> [dark]` writes a preview of the popover.
if let i = CommandLine.arguments.firstIndex(of: "--render-panel"), i + 1 < CommandLine.arguments.count {
    let dark = CommandLine.arguments.contains("dark")
    if CommandLine.arguments.contains("en") { Lang.current = .en }
    _ = NSApplication.shared
    Snapshot.active = true
    // Demo identity only — screenshots must never contain a real serial, token or address.
    let st = Station(sn: "HS2C0DEMO000001", capacityOverride: nil, moduleWh: 2520, tau: 60)
    st.seedPreview()
    let m = PanelModel(); m.station = st
    m.stationName = "Jackery SolarVault 3 Pro Max AC"
    if CommandLine.arguments.contains("settings") {
        var dr = SettingsDraft()
        dr.host = "192.168.1.50"; dr.port = "1883"; dr.username = "jackery"; dr.password = "demo-password"
        dr.deviceSn = "HS2C0DEMO000001"; dr.token = "00000000"; dr.topicPrefix = "hb"
        m.draft = dr
        m.showSettings = true
    }
    if CommandLine.arguments.contains("outages") { m.showOutages = true }
    if CommandLine.arguments.contains("outage") { m.showOutages = true; m.outageStart = st.grid.outages.last?.start }
    if let k = CommandLine.arguments.firstIndex(of: "detail"), k + 1 < CommandLine.arguments.count {
        m.detail = Metric(rawValue: CommandLine.arguments[k + 1])
    }
    let view = PanelView(model: m)
        .background(dark ? Color(white: 0.13) : Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(10)
        .environment(\.colorScheme, dark ? .dark : .light)
    let rep = MainActor.assumeIsolated { () -> NSBitmapImageRep in
        let r = ImageRenderer(content: view); r.scale = 2
        return NSBitmapImageRep(cgImage: r.cgImage!)
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// `--render <file.png>` writes a sample status image (used for previewing the look).
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    if CommandLine.arguments.contains("en") { Lang.current = .en }
    let samples: [(Double, Bool, [Renderer.Column])] = [
        (73, false, [.init(caption: L("ЗАРЯД", "CHARGE"), value: "73%"), .init(caption: L("ЗАПАС", "LEFT"), value: "~" + Fmt.durationShort(5 + 10.0 / 60))]),
        (54, false, [.init(caption: L("ЗАРЯД", "CHARGE"), value: "54%"), .init(caption: L("БЕЗ СВІТЛА", "OUTAGE"), value: "~" + Fmt.durationShort(2 + 14.0 / 60))]),
        (41, true, [.init(caption: L("ЗАРЯД", "CHARGE"), value: "41%"), .init(caption: L("ДО 100%", "TO 100%"), value: "~" + Fmt.durationShort(1.25))]),
    ]
    let scale: CGFloat = 3, h: CGFloat = 30
    let imgs = samples.map { Renderer.image(soc: $0.0, charging: $0.1, columns: $0.2, dimmed: false, height: h) }
    let w = imgs.map(\.size.width).reduce(0, +) + 20 * CGFloat(imgs.count + 1)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.15, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    var x: CGFloat = 20
    for img in imgs {
        // Tint the template white, like the menu bar does on a dark/coloured background.
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
        x += img.size.width + 20
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
