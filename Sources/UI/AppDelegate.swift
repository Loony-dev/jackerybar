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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        popup.onEscape = { [weak self] in
            guard let self, self.panel.page != .main else { return false }
            self.panel.back()
            return true
        }

        hub.onUpdate = { [weak self] in self?.redraw() }
        hub.onGrid = { [weak self] st, on, ended in self?.notifyGrid(st, on: on, ended: ended) }
        hub.onLowBattery = { [weak self] st, level in self?.notifyLowBattery(st, level: level) }

        if CommandLine.arguments.contains("--demo") {
            hub.startDemo()
        } else {
            apply(Config.load())
        }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.togglePopup() }
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

    private func post(_ c: UNMutableNotificationContent, station st: Station, page: String) {
        c.sound = .default
        c.userInfo = ["sn": st.sn, "page": page]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
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
            self.panel.page = (info["page"] as? String) == "outages" ? .outages : .main
            if !self.popup.isVisible, let b = self.item.button { self.redraw(); self.popup.show(below: b) }
        }
        done()
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
