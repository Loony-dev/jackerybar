// JackeryBar — menu bar widget for Jackery SolarVault 3 (local MQTT).
//
// Command-line helpers (used by scripts/screenshots.sh):
//   --render <png> [en]                         menu bar samples
//   --render-panel <png> [dark] [en] [page …]   popup with demo data; page = metric <name> | outages | outage | stats | control | settings
//   --demo                                      run with a synthetic station
//   --register-login                            register launch at login

import Cocoa
import ServiceManagement
import SwiftUI

let args = CommandLine.arguments

if args.contains("--register-login") {
    do { try SMAppService.mainApp.register(); print("login item:", SMAppService.mainApp.status.rawValue) }
    catch { print("login item error:", error) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-panel"), i + 1 < args.count {
    let dark = args.contains("dark")
    if args.contains("en") { Lang.current = .en }
    _ = NSApplication.shared
    Snapshot.active = true
    let hub = Hub()
    let stations = PreviewData.stations()
    hub.showPreview(stations, selected: stations[0].sn)
    let (sched, regions) = PreviewData.schedule()
    hub.schedules.inject(sched, index: regions)
    if args.contains("disagree"), sched.days.count > 1, var ints = sched.days[1].groups["1.1"], ints.count > 1 {
        // Second source that read tomorrow's evening outage differently.
        var other = sched
        ints[1].to = "19:00"; other.days[1].groups["1.1"] = ints; other.feed = "frankov"
        hub.schedules.injectSecondary(other)
    }
    // A recent change to show on the schedule page: tomorrow's evening outage moved by an hour.
    var older = sched
    if older.days.count > 1, var ints = older.days[1].groups["1.1"], ints.count > 1 {
        ints[1].from = "17:00"; older.days[1].groups["1.1"] = ints
        stations[0].lastScheduleChange = (Date().addingTimeInterval(-1500),
                                          ScheduleChange.diff(old: older, new: sched, group: "1.1", today: RegionSchedule.dayString()))
    }
    let m = PanelModel(hub: hub)
    if let k = args.firstIndex(of: "metric"), k + 1 < args.count, let metric = Metric(rawValue: args[k + 1]) {
        m.page = .metric(metric)
        if let r = args.firstIndex(of: "range"), r + 1 < args.count, let s = Double(args[r + 1]) { m.range = s }
    } else if args.contains("outage") {
        m.page = .outage(stations[0].grid.outages.last!.start)
    } else if args.contains("outages") {
        m.page = .outages
    } else if args.contains("schedule") {
        m.page = .schedule
    } else if args.contains("queue") {
        m.addressQuery = .init(settlement: "Хмельницький", street: "Проскурівська", house: "1")
        m.addressResults = [AddressMatch(district: "Хмельницький РЕМ побут", settlement: "Хмельницький", street: "вул. Проскурівська", queue: "1.1", exactHouse: true)]
        m.addressSearched = true
        m.page = .queue
    } else if args.contains("stats") {
        m.statsDays = 30
        if args.contains("cost") { m.statsKind = .cost }
        m.page = .stats
    } else if args.contains("control") {
        m.controlDraft = ["socChgLimit": 90]
        m.page = .control
    } else if args.contains("settings") {
        var d = SettingsDraft(hub.config!)
        d.host = "192.168.1.50"; d.username = "jackery"; d.password = "demo-password"
        m.draft = d
        m.verify = [d.stations[0].id: .done(.ok)]
        m.found = [FoundStation(sn: "HS2C0DEMO000003", ip: "192.168.1.77", seen: Date().timeIntervalSince1970 - 120)]
        m.dataSize = 3_400_000
        m.draft.tgOn = true; m.draft.tgToken = "000000:demo"; m.draft.tgChat = "123456789"
        m.draft.smartOn = true; m.draft.tariffNightOn = true
        m.page = .settings
    }
    let view = PanelView(model: m, measuring: true)
        .background(dark ? Color(white: 0.13) : Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(10)
        .environment(\.colorScheme, dark ? .dark : .light)
    let cg = MainActor.assumeIsolated { () -> CGImage in
        let r = ImageRenderer(content: view); r.scale = 2
        return r.cgImage!
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}

if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    let out = URL(fileURLWithPath: args[i + 1])
    if args.contains("en") { Lang.current = .en }
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
        // Tint the template white, like the menu bar does on a dark background.
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
