// State of the popup: which page is open, page-local choices, the settings form.

import SwiftUI

enum Page: Equatable {
    case main
    case metric(Metric)
    case outages
    case outage(Double)       // start time
    case stats
    case control
    case settings
    case schedule
    case queue                // outage-queue picker for the selected station
}

enum StatsKind: String, CaseIterable {
    case consumed, discharged, imported, cost, outage, solar

    var title: String {
        switch self {
        case .consumed: L("Спожито", "Consumed")
        case .discharged: L("Від батареї", "From battery")
        case .imported: L("З мережі", "From grid")
        case .outage: L("Без світла", "Outages")
        case .solar: L("Сонце", "Solar")
        case .cost: L("Вартість", "Cost")
        }
    }
}

final class PanelModel: ObservableObject {
    let hub: Hub
    @Published var tick = 0
    var station: Station? { hub.selected }

    @Published var page: Page = .main { didSet { layout() } }
    @Published var range: TimeInterval = 3600
    @Published var statsDays = 7 { didSet { layout() } }
    @Published var statsKind: StatsKind = .consumed

    // Control page
    @Published var controlDraft: [String: Int] = [:]
    @Published var confirming: JackeryProtocol.Command? { didSet { layout() } }

    // Settings page
    @Published var draft = SettingsDraft()
    @Published var settingsError: String? { didSet { layout() } }
    @Published var verify: [UUID: VerifyState] = [:]
    @Published var found: [FoundStation] = []
    @Published var dataSize: Int64 = 0
    @Published var confirmClear = false { didSet { layout() } }
    @Published var cleared = false

    enum VerifyState: Equatable { case checking, done(Hub.VerifyResult) }

    // Queue picker / address search
    struct AddressQuery { var settlement = "Хмельницький"; var street = ""; var house = "" }
    @Published var addressQuery = AddressQuery()
    @Published var addressResults: [AddressMatch] = [] { didSet { layout() } }
    @Published var addressLoading = false { didSet { layout() } }
    @Published var addressError: String? { didSet { layout() } }
    @Published var addressSearched = false

    /// Region shown in the queue picker before a queue is chosen.
    @Published var queueRegion = "khmelnytskyi"

    func openQueuePicker() {
        queueRegion = station?.config.region ?? "khmelnytskyi"
        addressResults = []; addressSearched = false; addressError = nil
        if hub.schedules.index.isEmpty { hub.schedules.fetchIndex() }
        page = .queue
    }

    /// Saves the queue for the selected station and shows its schedule.
    func pickQueue(_ q: String?, region: String) {
        guard let st = station else { return }
        hub.setQueue(st.sn, region: region, queue: q)
        if q != nil { addressResults = []; addressSearched = false; page = .schedule }
    }

    func searchAddress() {
        addressError = nil
        addressLoading = true
        hub.addresses.load { [weak self] err in
            guard let self else { return }
            self.addressLoading = false
            self.addressError = err.map { L("Не вдалося завантажити файли черг: \($0)", "Couldn’t download the queue files: \($0)") }
            let q = self.addressQuery
            self.addressResults = self.hub.addresses.search(settlement: q.settlement, street: q.street, house: q.house)
            self.addressSearched = true
        }
    }

    // Telegram / export / test notifications
    @Published var telegramStatus: String?
    @Published var exportStatus: String?
    var onTestNotifications: () -> Void = {}

    func findTelegramChat() {
        telegramStatus = L("Шукаю…", "Looking…")
        Telegram.findChat(token: draft.tgToken.trimmingCharacters(in: .whitespaces)) { [weak self] r in
            switch r {
            case .success(let c): self?.draft.tgChat = c.id; self?.telegramStatus = L("Знайдено чат «\(c.name)»", "Found chat “\(c.name)”")
            case .failure(let e): self?.telegramStatus = e.localizedDescription
            }
        }
    }

    func testTelegram() {
        telegramStatus = L("Надсилаю…", "Sending…")
        let cfg = TelegramConfig(enabled: true, token: draft.tgToken.trimmingCharacters(in: .whitespaces), chatId: draft.tgChat.trimmingCharacters(in: .whitespaces))
        Telegram.send(cfg, text: L("JackeryBar: тестове повідомлення ✅", "JackeryBar: test message ✅")) { [weak self] err in
            self?.telegramStatus = err ?? L("Надіслано — перевір Telegram", "Sent — check Telegram")
        }
    }

    func exportCSV() {
        do {
            let dir = try Export.write(stations: hub.stations, tariff: hub.config?.price ?? TariffConfig())
            exportStatus = L("Збережено: Завантаження/\(dir.lastPathComponent)", "Saved: Downloads/\(dir.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } catch {
            exportStatus = L("Не вдалося: \(error.localizedDescription)", "Failed: \(error.localizedDescription)")
        }
    }

    // Wired by AppDelegate
    var onOpenConfig: () -> Void = {}
    var onReload: () -> Void = {}
    var onSave: (Config) -> String? = { _ in nil }
    var onLanguage: (Lang) -> Void = { _ in }
    var onLayoutChange: () -> Void = {}

    init(hub: Hub) { self.hub = hub }

    private func layout() { DispatchQueue.main.async { self.onLayoutChange() } }

    func open(_ p: Page) {
        confirming = nil
        if p == .control { controlDraft = [:] }
        page = p
    }

    /// One level up.
    func back() {
        confirming = nil
        switch page {
        case .outage: page = .outages
        case .queue:
            addressResults = []; addressSearched = false
            page = station?.config.queue == nil ? .main : .schedule
        case .settings: settingsError = nil; confirmClear = false; page = .main
        default: page = .main
        }
    }

    // MARK: settings

    func openSettings() {
        draft = hub.config.map(SettingsDraft.init) ?? Config.load().map(SettingsDraft.init) ?? SettingsDraft()
        if draft.stations.isEmpty { draft.stations = [StationDraft()] }
        settingsError = nil
        verify = [:]
        confirmClear = false
        cleared = false
        telegramStatus = nil
        exportStatus = nil
        dataSize = Paths.dataSize()
        found = Discovery.scan()
        page = .settings
    }

    func saveSettings() {
        switch draft.build() {
        case .failure(let e): settingsError = e.message
        case .success(let cfg):
            if let err = onSave(cfg) { settingsError = err } else { settingsError = nil; page = .main }
        }
    }

    func check(_ s: StationDraft) {
        let sn = s.sn.trimmingCharacters(in: .whitespaces), token = s.token.trimmingCharacters(in: .whitespaces)
        guard !sn.isEmpty, !token.isEmpty else { return }
        verify[s.id] = .checking
        hub.verify(sn: sn, token: token) { [weak self] r in self?.verify[s.id] = .done(r) }
    }

    func addFound(_ f: FoundStation) {
        if let i = draft.stations.firstIndex(where: { $0.sn.trimmingCharacters(in: .whitespaces).isEmpty }) {
            draft.stations[i].sn = f.sn
        } else {
            var s = StationDraft(); s.sn = f.sn
            draft.stations.append(s)
        }
        layout()
    }

    func clearData() {
        hub.clearAllData()
        hub.addresses.removeCache()
        dataSize = Paths.dataSize()
        confirmClear = false
        cleared = true
    }
}
