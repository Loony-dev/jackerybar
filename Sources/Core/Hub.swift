// Coordinates everything that isn't UI: one MQTT connection for all stations, polling,
// routing replies by serial number, commands, token checks, persistence and alerts.
// Runs on the main thread; MQTT callbacks are hopped to main.

import Foundation

final class Hub {
    private(set) var config: Config?
    private(set) var stations: [Station] = []
    /// nil while connected; otherwise why not.
    private(set) var connError: String? = L("Підключення…", "Connecting…")
    var isConnected: Bool { isDemo || (connError == nil && mqtt != nil) }

    // Callbacks (main thread).
    var onUpdate: () -> Void = {}
    var onGrid: (Station, Bool, GridLog.Outage?) -> Void = { _, _, _ in }
    var onLowBattery: (Station, Int) -> Void = { _, _ in }

    private var mqtt: MQTTClient?
    private var pollTimer: Timer?
    private var saveTimer: Timer?
    private var demoTimer: Timer?
    private(set) var isDemo = false

    enum VerifyResult: Equatable { case ok, wrongToken, noAnswer, notConnected }
    private var verifications: [Int: (sn: String, done: (VerifyResult) -> Void, timer: Timer)] = [:]

    // MARK: selection

    var selected: Station? {
        stations.first { $0.sn == config?.selected } ?? stations.first
    }

    func station(_ sn: String) -> Station? { stations.first { $0.sn == sn } }

    /// Shows another station in the menu bar and remembers it.
    func select(_ sn: String) {
        guard var c = config, c.selected != sn, station(sn) != nil else { return }
        c.selected = sn
        config = c
        if !isDemo { try? c.save() }
        onUpdate()
    }

    // MARK: lifecycle

    /// (Re)starts with a config. Stations that stay keep their in-memory state.
    func start(_ cfg: Config?) {
        stopConnection()
        let previous = Dictionary(uniqueKeysWithValues: stations.map { ($0.sn, $0) })
        config = cfg
        guard let cfg, cfg.isUsable else {
            stations.forEach { $0.save() }
            stations = []
            connError = nil
            onUpdate()
            return
        }

        var next: [Station] = []
        for sc in cfg.stations where !next.contains(where: { $0.sn == sc.deviceSn }) {
            if let st = previous[sc.deviceSn] {
                st.update(config: sc)
                next.append(st)
            } else {
                let st = Station(config: sc, tau: cfg.smoothingSeconds ?? 60)
                st.load()
                next.append(st)
            }
        }
        for (sn, st) in previous where !next.contains(where: { $0.sn == sn }) { st.save() }
        stations = next
        for st in stations { wireGrid(st) }

        connError = L("Підключення…", "Connecting…")
        let client = MQTTClient(broker: Broker(cfg), topics: JackeryProtocol.subscriptions(cfg.prefix))
        client.onMessage = { [weak self] topic, payload in
            DispatchQueue.main.async { self?.handle(topic: topic, payload: payload) }
        }
        client.onStatus = { [weak self] err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connError = err
                if err == nil { self.poll() }
                self.onUpdate()
            }
        }
        mqtt = client
        client.start()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.saveAll() }
        onUpdate()
    }

    private func wireGrid(_ st: Station) {
        st.grid.onChange = { [weak self, weak st] on, ended in
            guard let self, let st else { return }
            if !self.isDemo {
                st.snapshotOutages()
                st.grid.save(to: Paths.file(.outages, st.sn))
            }
            self.onGrid(st, on, ended)
        }
    }

    private func stopConnection() {
        mqtt?.stop()
        mqtt = nil
        pollTimer?.invalidate(); pollTimer = nil
        saveTimer?.invalidate(); saveTimer = nil
        for v in verifications.values { v.timer.invalidate(); v.done(.notConnected) }
        verifications.removeAll()
    }

    func stop() {
        stopConnection()
        demoTimer?.invalidate()
        saveAll()
    }

    func saveAll() {
        guard !isDemo else { return }
        stations.forEach { $0.save() }
    }

    // MARK: MQTT

    private func poll() {
        guard let cfg = config, let mqtt, connError == nil else { return }
        for st in stations {
            let topic = JackeryProtocol.topic(cfg.prefix, st.sn, "action")
            for type in JackeryProtocol.pollTypes {
                mqtt.publish(topic, JackeryProtocol.request(type: type, token: st.config.token))
            }
        }
    }

    private func handle(topic: String, payload: Data) {
        guard let cfg = config, let (sn, _) = JackeryProtocol.parse(topic: topic, prefix: cfg.prefix),
              let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }

        if let id = json["messageId"] as? Int, let v = verifications[id], v.sn == sn {
            v.timer.invalidate()
            verifications[id] = nil
            let rejected = (json["type"] as? Int) == 123
            v.done(rejected ? .wrongToken : .ok)
            return
        }
        guard let st = station(sn) else { return }
        switch st.ingest(json) {
        case .data:
            checkLowBattery(st)
            onUpdate()
        case .tokenRejected:
            onUpdate()
        case .ignored:
            break
        }
    }

    private func checkLowBattery(_ st: Station) {
        guard let cfg = config, cfg.alerts.enabled, let soc = st.soc else { return }
        if let t = st.lowBattery.check(soc: soc, discharging: st.isDischarging, thresholds: cfg.alerts.thresholds) {
            onLowBattery(st, t)
        }
    }

    // MARK: commands & checks

    /// Sends a settings change to a station. Returns false when not connected.
    @discardableResult
    func send(_ cmd: JackeryProtocol.Command, to st: Station) -> Bool {
        guard let cfg = config, let mqtt, connError == nil else { return false }
        mqtt.publish(JackeryProtocol.topic(cfg.prefix, st.sn, "action"), JackeryProtocol.command(cmd, token: st.config.token))
        st.markSent(cmd)
        // Ask right away so the new value shows up quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.poll() }
        onUpdate()
        return true
    }

    /// Checks a serial/token pair against the station (works for stations not saved yet).
    func verify(sn: String, token: String, done: @escaping (VerifyResult) -> Void) {
        guard let cfg = config, let mqtt, connError == nil else { done(.notConnected); return }
        let id = Int.random(in: 10_000...99_999)
        let timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            guard let self, let v = self.verifications[id] else { return }
            self.verifications[id] = nil
            v.done(.noAnswer)
        }
        verifications[id] = (sn, done, timer)
        mqtt.publish(JackeryProtocol.topic(cfg.prefix, sn, "action"),
                     JackeryProtocol.request(type: 25, token: token, messageId: id))
    }

    /// Deletes all history files and forgets in-memory history. config.json stays.
    func clearAllData() {
        for st in stations { st.clearHistory() }
        for url in Paths.dataFiles() { try? FileManager.default.removeItem(at: url) }
        onUpdate()
    }

    // MARK: demo

    /// A fake station fed with synthetic MQTT messages (`--demo`).
    func startDemo() {
        isDemo = true
        let sc = StationConfig(deviceSn: "HS2C0DEMO000001", token: "demo", name: "Jackery SolarVault 3 (demo)")
        config = Config(host: "demo", stations: [sc], selected: sc.deviceSn)
        let st = Station(config: sc)
        stations = [st]
        wireGrid(st)
        connError = nil
        var soc = 73.0
        let tick = { [weak self] in
            let t = Date().timeIntervalSince1970
            let load = 380 + 60 * sin(t / 9)
            soc = max(11, soc - (load * 1.08 + 22) * 2 / 3600 / 2520 * 100)
            _ = st.ingest(["type": 106, "body": [
                "soc": soc, "batInPw": 0, "batOutPw": load * 1.08 + 22, "swEpsOutPw": load, "swEpsInPw": 0,
                "gridInPw": 0, "gridOutPw": 0, "ongridStat": 0, "socDischgLimit": 10, "socChgLimit": 100,
                "batNum": 0, "cellTemp": 281, "minCellTemp": 270, "maxCellTemp": 289, "wsig": -44, "swEps": 1,
                "maxOutPw": 800,
            ] as [String: Any]])
            self?.onUpdate()
        }
        tick()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in tick() }
    }

    /// Stations prepared elsewhere (screenshots).
    func showPreview(_ list: [Station], selected: String?) {
        isDemo = true
        stations = list
        config = Config(host: "preview", stations: list.map(\.config), selected: selected)
        connError = nil
    }
}
