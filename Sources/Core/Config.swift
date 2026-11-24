// config.json: one MQTT broker, any number of stations, UI preferences.
// Older single-station files ({"deviceSn": …, "token": …}) are migrated on read.

import Foundation

struct StationConfig: Codable, Equatable, Identifiable {
    var deviceSn: String
    var token: String
    /// Display name; default "Jackery SolarVault 3".
    var name: String?
    /// Total capacity in Wh. If nil: moduleWh × (1 + expansion batteries reported by the station).
    var capacityWh: Double?
    /// Capacity of one battery module in Wh (SolarVault 3 Pro Max / Pro Max AC: 2520).
    var moduleWh: Double?

    var id: String { deviceSn }
    var displayName: String { (name?.isEmpty == false ? name : nil) ?? "Jackery SolarVault 3" }
}

struct LowBatteryConfig: Codable, Equatable {
    var enabled = true
    /// Notify once when the charge drops to each of these levels while discharging.
    var thresholds = [30, 15]
}

struct Config: Codable, Equatable {
    var host: String
    var port: Int?
    var username: String?
    var password: String?
    var topicPrefix: String?
    var stations: [StationConfig]
    /// Serial number of the station shown in the menu bar.
    var selected: String?
    /// Popup theme: "dark" (default), "light" or "system".
    var theme: String?
    /// UI language: "uk" (default) or "en".
    var language: String?
    /// Window of power smoothing for the runtime estimate, seconds.
    var smoothingSeconds: Double?
    var lowBattery: LowBatteryConfig?

    var prefix: String { (topicPrefix?.isEmpty == false ? topicPrefix : nil) ?? "hb" }
    var alerts: LowBatteryConfig { lowBattery ?? LowBatteryConfig() }
    var isUsable: Bool { !host.isEmpty && !stations.isEmpty }

    init(host: String, port: Int? = 1883, username: String? = nil, password: String? = nil, topicPrefix: String? = "hb",
         stations: [StationConfig] = [], selected: String? = nil, theme: String? = nil, language: String? = nil,
         smoothingSeconds: Double? = nil, lowBattery: LowBatteryConfig? = nil) {
        self.host = host; self.port = port; self.username = username; self.password = password
        self.topicPrefix = topicPrefix; self.stations = stations; self.selected = selected
        self.theme = theme; self.language = language; self.smoothingSeconds = smoothingSeconds; self.lowBattery = lowBattery
    }

    // --- coding with migration from the single-station format

    private enum Keys: String, CodingKey {
        case host, port, username, password, topicPrefix, stations, selected, theme, language, smoothingSeconds, lowBattery
        // legacy single-station keys
        case deviceSn, token, name, capacityWh, moduleWh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        topicPrefix = try c.decodeIfPresent(String.self, forKey: .topicPrefix)
        selected = try c.decodeIfPresent(String.self, forKey: .selected)
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        smoothingSeconds = try c.decodeIfPresent(Double.self, forKey: .smoothingSeconds)
        lowBattery = try c.decodeIfPresent(LowBatteryConfig.self, forKey: .lowBattery)
        if let list = try c.decodeIfPresent([StationConfig].self, forKey: .stations) {
            stations = list
        } else if let sn = try c.decodeIfPresent(String.self, forKey: .deviceSn),
                  let token = try c.decodeIfPresent(String.self, forKey: .token) {
            stations = [StationConfig(deviceSn: sn, token: token,
                                      name: try c.decodeIfPresent(String.self, forKey: .name),
                                      capacityWh: try c.decodeIfPresent(Double.self, forKey: .capacityWh),
                                      moduleWh: try c.decodeIfPresent(Double.self, forKey: .moduleWh))]
        } else {
            stations = []
        }
        // Placeholders from the very first template are not real stations.
        stations.removeAll { $0.deviceSn.contains("СЕРИЙНЫЙ") || $0.token.contains("ТОКЕН") || $0.deviceSn.isEmpty }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(host, forKey: .host)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encodeIfPresent(password, forKey: .password)
        try c.encodeIfPresent(topicPrefix, forKey: .topicPrefix)
        try c.encode(stations, forKey: .stations)
        try c.encodeIfPresent(selected, forKey: .selected)
        try c.encodeIfPresent(theme, forKey: .theme)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(smoothingSeconds, forKey: .smoothingSeconds)
        try c.encodeIfPresent(lowBattery, forKey: .lowBattery)
    }

    // --- file

    static func load(from url: URL = Paths.config) -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    func save(to url: URL = Paths.config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Where everything lives: ~/.config/jackery-bar/.
enum Paths {
    static let config: URL = {
        if let i = CommandLine.arguments.firstIndex(of: "--config"), i + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/jackery-bar/config.json")
    }()
    static var dir: URL { config.deletingLastPathComponent() }

    enum Kind: String, CaseIterable {
        case metrics, longterm, outages, losses
    }

    static func file(_ kind: Kind, _ sn: String) -> URL {
        dir.appendingPathComponent("\(kind.rawValue)-\(sn.filter { $0.isLetter || $0.isNumber }).json")
    }

    /// All data files (everything except config.json).
    static func dataFiles() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let prefixes = Kind.allCases.map { $0.rawValue + "-" } + ["history-"]
        return items.filter { u in u.pathExtension == "json" && prefixes.contains { u.lastPathComponent.hasPrefix($0) } }
    }

    static func dataSize() -> Int64 {
        dataFiles().reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
