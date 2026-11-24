// Jackery SolarVault 3 local MQTT protocol (as used by Jackery's official Home Assistant integration).
//
//   <prefix>/device/<SN>/action   ← requests and commands (we publish)
//   <prefix>/device/<SN>/status   → replies
//   <prefix>/device/<SN>/event    → replies / sub-device data
//
// Every request carries the token the Jackery app shows. A wrong token gets {"type":123,"body":{"errorCode":401}}.

import Foundation

enum JackeryProtocol {
    /// Poll requests sent every few seconds: device status (25) and full system data (105).
    static let pollTypes = [25, 105]

    static func topic(_ prefix: String, _ sn: String, _ kind: String) -> String { "\(prefix)/device/\(sn)/\(kind)" }

    /// Subscriptions for every station at once (also lets us hear stations not configured yet).
    static func subscriptions(_ prefix: String) -> [String] {
        ["\(prefix)/device/+/status", "\(prefix)/device/+/event"]
    }

    /// "<prefix>/device/<SN>/<kind>" → (SN, kind).
    static func parse(topic: String, prefix: String) -> (sn: String, kind: String)? {
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == prefix, parts[1] == "device" else { return nil }
        return (parts[2], parts[3])
    }

    static func request(type: Int, token: String, messageId: Int = Int.random(in: 1000...9999)) -> Data {
        encode(["type": type, "eventId": 0, "messageId": messageId,
                "ts": Int(Date().timeIntervalSince1970), "token": token, "body": NSNull()])
    }

    /// Sub-device list request: devType 2 = CT meters, 6 = smart plugs. Answer: type 101 with "cts"/"plugs".
    static func subDevices(devType: Int, token: String) -> Data {
        encode(["type": 100, "eventId": 0, "messageId": Int.random(in: 1000...9999),
                "ts": Int(Date().timeIntervalSince1970), "token": token, "body": ["devType": devType]])
    }

    /// Smart plug on/off: type 103 {deviceSn, devType, sysSwitch}. Works only for plugs in local mode (commMode 1).
    static func plugSwitch(sn: String, devType: Int = 6, on: Bool, token: String) -> Data {
        encode(["type": 103, "eventId": 0, "messageId": Int.random(in: 1000...9999),
                "ts": Int(Date().timeIntervalSince1970), "token": token,
                "body": ["deviceSn": sn, "devType": devType, "sysSwitch": on ? 1 : 0]])
    }

    /// Settings change: type 1 / eventId 3 / body {cmd: 5, rc: 1, <key>: <value>}.
    static func command(_ cmd: Command, token: String, messageId: Int = Int.random(in: 1000...9999)) -> Data {
        var body: [String: Any] = ["cmd": 5, "rc": 1]
        body[cmd.key] = cmd.value
        return encode(["type": 1, "eventId": 3, "messageId": messageId,
                       "ts": Int(Date().timeIntervalSince1970), "token": token, "body": body])
    }

    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    /// Station settings that can be changed. Keys and ranges follow the official integration.
    enum Command: Equatable {
        case acOutlet(Bool)          // swEps: AC socket (EPS) output on/off
        case chargeLimit(Int)        // socChgLimit: 50…100 %
        case dischargeLimit(Int)     // socDischgLimit: 5…49 %
        case maxOutput(Int)          // maxOutPw: grid-port output limit, 0…2500 W
        case reboot

        var key: String {
            switch self {
            case .acOutlet: "swEps"
            case .chargeLimit: "socChgLimit"
            case .dischargeLimit: "socDischgLimit"
            case .maxOutput: "maxOutPw"
            case .reboot: "reboot"
            }
        }

        var value: Int {
            switch self {
            case .acOutlet(let on): on ? 1 : 0
            case .chargeLimit(let v), .dischargeLimit(let v), .maxOutput(let v): v
            case .reboot: 1
            }
        }

        static let chargeRange = 50...100
        static let dischargeRange = 5...49
        static let maxOutputRange = 0...2500
    }
}
