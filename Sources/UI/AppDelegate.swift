// App lifecycle: menu bar item, popup, notifications, wiring between Hub and the UI.

import Cocoa
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var item: NSStatusItem!
    private let hub = Hub()
    private lazy var panel = PanelModel(hub: hub)
    private lazy var popup = PopupWindow { [panel] measuring in PanelView(model: panel, measuring: measuring) }
    private var redrawTimer: Timer?
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ n: Notification) {
        handleSigterm()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            Self.log("notifications: requestAuthorization granted=\(granted) error=\(err.map { "\($0)" } ?? "-")")
            UNUserNotificationCenter.current().getNotificationSettings { s in
                Self.log("notifications: authorization=\(s.authorizationStatus.rawValue) alert=\(s.alertSetting.rawValue) style=\(s.alertStyle.rawValue) center=\(s.notificationCenterSetting.rawValue)")
            }
        }
        panel.refreshNotificationStatus()
        if CommandLine.arguments.contains("--test-notify") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.sendTestNotifications() }
        }
        installEditMenu()

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopup)

        panel.onOpenConfig = { [weak self] in
            self?.popup.close()
            NSWorkspace.shared.open(Paths.config)
        }
        panel.onReload = { [weak self] in self?.reload() }
        panel.onLayoutChange = { [weak self] in
            guard let self, self.popup.isVisible else { return }
            self.popup.fitToContent()
        }
        panel.onLanguage = { [weak self] lang in
            guard let self, lang != Lang.current else { return }
            Lang.current = lang
            if var c = Config.load() { c.language = lang.rawValue; try? c.save() }
            self.panel.draft.language = lang.rawValue
            self.installEditMenu()
            self.redraw()
        }
        panel.onSave = { [weak self] cfg in
            do { try cfg.save() } catch { return L("Не вдалося зберегти: \(error.localizedDescription)", "Couldn’t save: \(error.localizedDescription)") }
            self?.apply(cfg)
            return nil
        }
        popup.maxHeightFraction = { [panel] in panel.page == .settings ? 0.5 : nil }
        popup.onEscape = { [weak self] in
            guard let self, self.panel.page != .main else { return false }
            self.panel.back()
            return true
        }

        hub.onUpdate = { [weak self] in self?.redraw() }
        hub.onGrid = { [weak self] st, on, ended in self?.notifyGrid(st, on: on, ended: ended) }
        hub.onLowBattery = { [weak self] st, level in self?.notifyLowBattery(st, level: level) }
        hub.onPlannedSoon = { [weak self] st, o, fc in self?.notifyPlanned(st, o, fc) }
        hub.onScheduleChanged = { [weak self] st, ch in self?.notifyScheduleChanged(st, ch) }
        hub.onEmergency = { [weak self] region, active, note in self?.notifyEmergency(region, active, note) }
        hub.onSmartCharge = { [weak self] st, raised, why in self?.notifySmartCharge(st, raised, why) }
        panel.onTestNotifications = { [weak self] in self?.sendTestNotifications() }

        if CommandLine.arguments.contains("--demo") {
            hub.startDemo()
        } else {
            apply(Config.load())
        }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.togglePopup()
                if CommandLine.arguments.contains("--settings") { self.panel.openSettings() }
            }
        }
        redrawTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.redraw() }
    }

    func applicationWillTerminate(_ n: Notification) { hub.stop() }

    private func apply(_ cfg: Config?) {
        Lang.current = Lang(rawValue: cfg?.language ?? "uk") ?? .uk
        popup.theme = cfg?.theme ?? "dark"
        installEditMenu()
        hub.start(cfg)
    }

    private func reload() { apply(Config.load()) }

    /// SIGTERM (pkill, logout, reinstall) goes through a normal terminate so history gets saved.
    private func handleSigterm() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }

    // MARK: popup & menu bar

    @objc private func togglePopup() {
        guard let button = item.button else { return }
        if popup.isVisible {
            popup.close()
        } else {
            panel.page = .main
            panel.confirming = nil
            panel.refreshNotificationStatus()
            redraw()
            popup.show(below: button)
        }
    }

    private func redraw() {
        panel.tick &+= 1
        if popup.isVisible { DispatchQueue.main.async { self.popup.fitToContent() } }
        guard let button = item.button else { return }
        let h = NSStatusBar.system.thickness
        guard let st = hub.selected else {
            button.image = Renderer.image(soc: nil, charging: false,
                                          columns: [.init(caption: "JACKERY", value: L("налаштувати", "set up"))], dimmed: true, height: h)
            button.toolTip = "JackeryBar"
            return
        }
        let socText = st.soc.map { "\(Int($0.rounded()))%" } ?? "—"
        // Discharging/idle: how long the battery lasts. Charging: how long until it's full.
        let charging = st.isCharging
        let caption = charging ? L("ДО \(Int(st.maxSoc))%", "TO \(Int(st.maxSoc))%") : st.grid.isOn == false ? L("БЕЗ СВІТЛА", "OUTAGE") : L("ЗАПАС", "LEFT")
        let value = charging
            ? (st.toFullHours.map { $0 < 1.0 / 60 ? L("повна", "full") : "~" + Fmt.durationShort($0) } ?? "—")
            : (st.runtimeHours.map { $0.isFinite ? "~" + Fmt.durationShort($0) : "∞" } ?? "—")
        button.image = Renderer.image(soc: st.soc, charging: charging,
                                      columns: [.init(caption: L("ЗАРЯД", "CHARGE"), value: socText), .init(caption: caption, value: value)],
                                      dimmed: st.isStale || hub.connError != nil || st.tokenRejected, height: h)
        button.toolTip = hub.stations.map { s in
            "\(s.name): " + (s.soc.map { "\(Int($0.rounded()))%" } ?? "—")
        }.joined(separator: "\n")
        if CommandLine.arguments.contains("--debug") {
            FileHandle.standardError.write("[redraw] \(st.sn) err=\(hub.connError ?? "-") soc=\(socText) \(caption)=\(value) net=\(st.smoothedNet.map { String(Int($0)) } ?? "-") load=\(st.smoothedLoad.map { String(Int($0)) } ?? "-") cap=\(Int(st.capacityWh)) token=\(st.tokenRejected ? "REJECTED" : "ok")\n".data(using: .utf8)!)
        }
    }

    // MARK: notifications

    private func prefix(_ st: Station) -> String { hub.stations.count > 1 ? "\(st.name): " : "" }

    private func notifyGrid(_ st: Station, on: Bool, ended: GridLog.Outage?) {
        let c = UNMutableNotificationContent()
        let soc = st.soc.map { "\(Int($0.rounded()))%" } ?? "—"
        if on {
            c.title = L("Світло з’явилося", "Power is back")
            c.body = prefix(st) + (ended.map { L("Світла не було \(Fmt.span($0.duration)). ", "Outage lasted \(Fmt.span($0.duration)). ") } ?? "")
                + L("Заряд \(soc).", "Charge \(soc).")
        } else {
            c.title = L("Зникло світло", "Power outage")
            let rt = st.runtimeHours.map { $0.isFinite ? L(", вистачить на ~\(Fmt.duration($0))", ", lasts ~\(Fmt.duration($0))") : "" } ?? ""
            c.body = prefix(st) + L("станція на батареї: заряд \(soc)\(rt).", "station on battery: \(soc)\(rt).")
        }
        post(c, station: st, page: "outages")
    }

    private func notifyLowBattery(_ st: Station, level: Int) {
        let c = UNMutableNotificationContent()
        c.title = L("Низький заряд: \(Int((st.soc ?? Double(level)).rounded()))%", "Low battery: \(Int((st.soc ?? Double(level)).rounded()))%")
        if let h = st.runtimeHours, h.isFinite {
            let until = Fmt.clock(Date().timeIntervalSince1970 + h * 3600)
            c.body = prefix(st) + L("батареї вистачить ще на ~\(Fmt.duration(h)), до \(until).", "the battery lasts ~\(Fmt.duration(h)) more, until \(until).")
        } else {
            c.body = prefix(st) + L("заряд опустився до \(level)%.", "charge dropped to \(level)%.")
        }
        post(c, station: st, page: "main")
    }

    private func notifyPlanned(_ st: Station, _ o: PlannedOutage, _ fc: PlanForecast?) {
        let c = UNMutableNotificationContent()
        let mins = Int((o.start.timeIntervalSinceNow / 60).rounded())
        let span = "\(Fmt.clock(o.start.timeIntervalSince1970))–\(Fmt.clock(o.end.timeIntervalSince1970))"
        c.title = L("Через \(max(mins, 1)) хв відключення за графіком", "Scheduled outage in \(max(mins, 1)) min")
        var body = prefix(st) + L("\(span), черга \(st.config.queue ?? "—").", "\(span), queue \(st.config.queue ?? "—").")
        if let fc {
            let soc = Int(fc.socAtStart.rounded())
            body += fc.runtimeHours.isInfinite
                ? L(" Заряд ~\(soc)%.", " Charge ~\(soc)%.")
                : fc.enough
                    ? L(" Заряд ~\(soc)% — вистачить на ~\(Fmt.duration(fc.runtimeHours)).", " Charge ~\(soc)% — lasts ~\(Fmt.duration(fc.runtimeHours)).")
                    : L(" Заряд ~\(soc)% — НЕ вистачить: ~\(Fmt.duration(fc.runtimeHours)) з \(Fmt.duration(fc.outageHours)).",
                        " Charge ~\(soc)% — NOT enough: ~\(Fmt.duration(fc.runtimeHours)) of \(Fmt.duration(fc.outageHours)).")
        }
        c.body = body
        post(c, station: st, page: "schedule")
    }

    private func notifyScheduleChanged(_ st: Station, _ ch: ScheduleChange) {
        let c = UNMutableNotificationContent()
        let q = st.config.queue ?? "—"
        c.title = ch.isOnlyPublication
            ? L("Графік на завтра: черга \(q)", "Tomorrow’s schedule: queue \(q)")
            : L("Графік змінився: черга \(q)", "Schedule changed: queue \(q)")
        var lines = ch.lines(today: RegionSchedule.dayString(), tomorrow: RegionSchedule.dayString(offset: 1))
        // Warn if, with the new schedule, the battery won't last through an upcoming outage.
        let plan = hub.plan(for: st)
        if let (o, fc) = zip(plan, st.forecasts(plan)).first(where: { $0.1.map { !$0.enough } ?? false }), let fc {
            lines.append(L("⚠︎ На \(Fmt.clock(o.start.timeIntervalSince1970))–\(Fmt.clock(o.end.timeIntervalSince1970)) заряду не вистачить: ~\(Fmt.duration(fc.runtimeHours)) з \(Fmt.duration(fc.outageHours)).",
                           "⚠︎ \(Fmt.clock(o.start.timeIntervalSince1970))–\(Fmt.clock(o.end.timeIntervalSince1970)): the battery won’t last, ~\(Fmt.duration(fc.runtimeHours)) of \(Fmt.duration(fc.outageHours))."))
        }
        c.body = prefix(st) + lines.joined(separator: "\n")
        post(c, station: st, page: "schedule")
    }

    private func notifyEmergency(_ region: String, _ active: Bool, _ note: String?) {
        let c = UNMutableNotificationContent()
        c.title = active ? L("Аварійні відключення: \(region)", "Emergency outages: \(region)")
                         : L("Аварійні відключення скасовано: \(region)", "Emergency outages lifted: \(region)")
        c.body = active ? (note ?? L("Графіки погодинних відключень можуть не діяти.", "Hourly schedules may not apply."))
                        : L("Знову діє графік погодинних відключень.", "The hourly schedule applies again.")
        if let st = hub.selected { post(c, station: st, page: "schedule") } else { post(c) }
    }

    private func notifySmartCharge(_ st: Station, _ raised: Bool, _ why: String) {
        let c = UNMutableNotificationContent()
        c.title = raised ? L("Розумна зарядка: до 100%", "Smart charging: to 100%") : L("Розумна зарядка завершена", "Smart charging done")
        c.body = prefix(st) + why
        post(c, station: st, page: "schedule")
    }

    /// One of each kind, so you can see (and check Telegram) what they look like.
    private func sendTestNotifications() {
        let st = hub.selected
        let samples: [(String, String)] = [
            (L("Зникло світло", "Power outage"), L("станція на батареї: заряд 77%, вистачить на ~5 год 10 хв.", "station on battery: 77%, lasts ~5h 10m.")),
            (L("Світло з’явилося", "Power is back"), L("Світла не було 2 год 14 хв. Заряд 41%.", "Outage lasted 2h 14m. Charge 41%.")),
            (L("Низький заряд: 15%", "Low battery: 15%"), L("батареї вистачить ще на ~1 год 10 хв, до 21:40.", "the battery lasts ~1h 10m more, until 21:40.")),
            (L("Через 30 хв відключення за графіком", "Scheduled outage in 30 min"), L("16:00–20:00, черга 1.1. Заряд ~86% — вистачить на ~5 год.", "16:00–20:00, queue 1.1. Charge ~86% — lasts ~5h.")),
            (L("Графік змінився: черга 1.1", "Schedule changed: queue 1.1"), L("Сьогодні: 19:00–22:00 → 18:00–22:00. Без світла 6 → 7 год.", "Today: 19:00–22:00 → 18:00–22:00. Without power 6 → 7 h.")),
            (L("Аварійні відключення: Хмельницька", "Emergency outages: Khmelnytskyi"), L("Графіки погодинних відключень можуть не діяти.", "Hourly schedules may not apply.")),
            (L("Розумна зарядка: до 100%", "Smart charging: to 100%"), L("Ліміт заряду піднято з 90% до 100% перед відключенням 16:00–20:00.", "Charge limit raised from 90% to 100% before the 16:00–20:00 outage.")),
        ]
        for (i, s) in samples.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                let c = UNMutableNotificationContent()
                c.title = L("[Тест] ", "[Test] ") + s.0
                c.body = s.1
                if let st { self.post(c, station: st, page: "main") } else { self.post(c) }
            }
        }
    }

    private func post(_ c: UNMutableNotificationContent, station st: Station? = nil, page: String = "main") {
        c.sound = .default
        if let st { c.userInfo = ["sn": st.sn, "page": page] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
            Self.log("notification '\(c.title)': " + (err.map { "FAILED \($0)" } ?? "delivered to the system"))
        }
        // Same text to Telegram, if set up.
        if let tg = hub.config?.telegram, tg.isUsable {
            Telegram.send(tg, text: "\(c.title)\n\(c.body)")
        }
    }

    // Show banners even if the app happens to be frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // Clicking a notification opens the right station and page.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            if let sn = info["sn"] as? String { self.hub.select(sn) }
            switch info["page"] as? String {
            case "outages": self.panel.page = .outages
            case "schedule": self.panel.page = .schedule
            default: self.panel.page = .main
            }
            if !self.popup.isVisible, let b = self.item.button { self.redraw(); self.popup.show(below: b) }
        }
        done()
    }

    /// Diagnostics for --debug runs.
    static func log(_ s: String) {
        guard CommandLine.arguments.contains("--debug") else { return }
        FileHandle.standardError.write("[app] \(s)\n".data(using: .utf8)!)
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
}
