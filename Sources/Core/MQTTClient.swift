// Minimal MQTT 3.1.1 client (QoS 0) over Network.framework — no third-party dependencies.

import Foundation
import Network

struct Broker: Equatable {
    var host: String
    var port: Int = 1883
    var username: String?
    var password: String?

    init(host: String, port: Int = 1883, username: String? = nil, password: String? = nil) {
        self.host = host; self.port = port; self.username = username; self.password = password
    }

    init(_ c: Config) { self.init(host: c.host, port: c.port ?? 1883, username: c.username, password: c.password) }
}

final class MQTTClient {
    var onMessage: ((String, Data) -> Void)?
    var onStatus: ((String?) -> Void)?   // nil = connected, otherwise error text

    private let broker: Broker
    private let topics: [String]
    private let queue = DispatchQueue(label: "jackerybar.mqtt")
    private var conn: NWConnection?
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var packetId: UInt16 = 1
    private var stopped = false

    init(broker: Broker, topics: [String]) {
        self.broker = broker
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
        let port = NWEndpoint.Port(rawValue: UInt16(clamping: broker.port)) ?? 1883
        let c = NWConnection(host: NWEndpoint.Host(broker.host), port: port, using: .tcp)
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
        if let u = broker.username, !u.isEmpty {
            flags |= 0x80
            payload.append(Self.str(u))
            if let p = broker.password, !p.isEmpty {
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
