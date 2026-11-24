// Finds SolarVault stations on a local Mosquitto broker.
//
// The station doesn't publish anything on its own, but it connects to the broker with its
// serial number as the MQTT client id, and Mosquitto logs every connection:
//   1795544123: New client connected from 192.168.1.77:52042 as HS2C0TEST00001 (p4, c1, k60, u'jackery').

import Foundation

struct FoundStation: Equatable {
    var sn: String
    var ip: String
    var seen: Double
}

enum Discovery {
    /// Where Homebrew's Mosquitto writes its log when `log_dest file …` is set (scripts/setup-mosquitto.sh does it).
    static let logPaths = ["/opt/homebrew/var/log/mosquitto.log", "/usr/local/var/log/mosquitto.log"]

    /// Stations seen in the broker log, most recent first.
    static func scan(paths: [String] = logPaths, maxBytes: Int = 1 << 20) -> [FoundStation] {
        for p in paths {
            guard let h = FileHandle(forReadingAtPath: p) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
            let data = (try? h.readToEnd()) ?? Data()
            let found = parse(String(decoding: data, as: UTF8.self))
            if !found.isEmpty { return found }
        }
        return []
    }

    /// Jackery serials are upper-case letters and digits, 12–20 chars (e.g. HS2C0TEST00001).
    static func looksLikeSerial(_ id: String) -> Bool {
        guard (12...20).contains(id.count) else { return false }
        return id.allSatisfy { ($0.isLetter && $0.isUppercase && $0.isASCII) || $0.isNumber }
            && id.contains(where: { $0.isLetter }) && id.contains(where: { $0.isNumber })
    }

    static func parse(_ log: String) -> [FoundStation] {
        var latest: [String: FoundStation] = [:]
        for line in log.split(separator: "\n") {
            guard let r = line.range(of: ": New client connected from ") else { continue }
            let time = Double(line[line.startIndex..<r.lowerBound]) ?? 0
            let rest = line[r.upperBound...]
            guard let asR = rest.range(of: " as ") else { continue }
            let addr = String(rest[rest.startIndex..<asR.lowerBound])
            let afterAs = rest[asR.upperBound...]
            let id = String(afterAs.prefix { $0 != " " })
            guard looksLikeSerial(id) else { continue }
            // "192.168.1.77:52042" → "192.168.1.77"
            let ip = addr.contains("]") ? String(addr.split(separator: "]").first ?? "").replacingOccurrences(of: "[", with: "")
                                        : String(addr.split(separator: ":").first ?? "")
            if (latest[id]?.seen ?? -1) <= time { latest[id] = FoundStation(sn: id, ip: ip, seen: time) }
        }
        return latest.values.sorted { $0.seen > $1.seen }
    }
}
