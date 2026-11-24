// Settings page: broker, stations (with discovery and token check), alerts, look, data.

import SwiftUI
import ServiceManagement

struct StationDraft: Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var sn = ""
    var token = ""
    var capacityAuto = true
    var capacityKWh = ""
    var moduleWh: Double?
    // Outage queue is chosen on the schedule page; kept here so saving settings doesn't drop it.
    var region: String?
    var queue: String?

    init() {}

    init(_ c: StationConfig) {
        region = c.region
        queue = c.queue
        name = c.name ?? ""
        sn = c.deviceSn
        token = c.token
        capacityAuto = c.capacityWh == nil
        capacityKWh = c.capacityWh.map { String(format: "%.2f", $0 / 1000) } ?? ""
        moduleWh = c.moduleWh
    }
}

/// Editable, string-based copy of Config for the form.
struct SettingsDraft {
    var host = ""
    var port = "1883"
    var username = ""
    var password = ""
    var prefix = "hb"
    var stations: [StationDraft] = []
    var theme = "dark"
    var language = "uk"
    var alertsOn = true
    var thresholds = "30, 15"
    var planOn = true
    var planMinutes = "30"
    var planChanges = true
    // Not shown in the form, preserved on save.
    var selected: String?
    var smoothingSeconds: Double?

    init() {}

    init(_ c: Config) {
        host = c.host
        port = String(c.port ?? 1883)
        username = c.username ?? ""
        password = c.password ?? ""
        prefix = c.prefix
        stations = c.stations.map(StationDraft.init)
        theme = c.theme ?? "dark"
        language = c.language ?? Lang.current.rawValue
        alertsOn = c.alerts.enabled
        thresholds = c.alerts.thresholds.map(String.init).joined(separator: ", ")
        planOn = c.plan.enabled
        planMinutes = String(c.plan.minutesBefore)
        planChanges = c.plan.notifyChanges
        selected = c.selected
        smoothingSeconds = c.smoothingSeconds
    }

    /// Validates the form and builds a Config, or returns an error message.
    func build() -> Result<Config, SettingsError> {
        func fail(_ uk: String, _ en: String) -> Result<Config, SettingsError> { .failure(SettingsError(L(uk, en))) }
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return fail("Вкажи адресу брокера", "Enter the broker address") }
        guard let port = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port)
        else { return fail("Порт має бути числом від 1 до 65535", "Port must be a number from 1 to 65535") }

        var list: [StationConfig] = []
        for (i, s) in stations.enumerated() {
            let sn = s.sn.trimmingCharacters(in: .whitespaces), token = s.token.trimmingCharacters(in: .whitespaces)
            if sn.isEmpty && token.isEmpty && s.name.isEmpty { continue }      // untouched empty row
            let n = i + 1
            guard !sn.isEmpty else { return fail("Станція \(n): вкажи серійний номер", "Station \(n): enter the serial number") }
            guard !token.isEmpty else { return fail("Станція \(n): вкажи токен із застосунку Jackery", "Station \(n): enter the token from the Jackery app") }
            guard !list.contains(where: { $0.deviceSn == sn }) else { return fail("Станція \(sn) додана двічі", "Station \(sn) is listed twice") }
            var cap: Double?
            if !s.capacityAuto {
                guard let kwh = Double(s.capacityKWh.replacingOccurrences(of: ",", with: ".")), kwh > 0
                else { return fail("Станція \(n): ємність — число в кВт·год, наприклад 5.04", "Station \(n): capacity must be in kWh, e.g. 5.04") }
                cap = kwh * 1000
            }
            let name = s.name.trimmingCharacters(in: .whitespaces)
            list.append(StationConfig(deviceSn: sn, token: token, name: name.isEmpty ? nil : name,
                                      capacityWh: cap, moduleWh: s.moduleWh,
                                      region: s.queue == nil ? nil : s.region, queue: s.queue))
        }
        guard !list.isEmpty else { return fail("Додай хоча б одну станцію", "Add at least one station") }

        let levels = thresholds.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).compactMap { Int($0) }
        guard !alertsOn || (!levels.isEmpty && levels.allSatisfy { (1...99).contains($0) })
        else { return fail("Пороги заряду — числа від 1 до 99 через кому", "Charge levels must be numbers 1–99, comma-separated") }

        guard let minutes = Int(planMinutes.trimmingCharacters(in: .whitespaces)), (1...240).contains(minutes) || !planOn
        else { return fail("Попередження про графік — від 1 до 240 хв", "Schedule warning must be 1–240 min") }

        let pfx = prefix.trimmingCharacters(in: .whitespaces)
        return .success(Config(host: host, port: port,
                               username: username.isEmpty ? nil : username,
                               password: password.isEmpty ? nil : password,
                               topicPrefix: pfx.isEmpty ? "hb" : pfx,
                               stations: list,
                               selected: list.contains(where: { $0.deviceSn == selected }) ? selected : list.first?.deviceSn,
                               theme: theme == "dark" ? nil : theme,
                               language: language,
                               smoothingSeconds: smoothingSeconds,
                               lowBattery: LowBatteryConfig(enabled: alertsOn, thresholds: Array(Set(levels)).sorted(by: >)),
                               planAlerts: PlanAlertConfig(enabled: planOn, minutesBefore: minutes, changes: planChanges)))
    }
}

struct SettingsError: Error {
    let message: String
    init(_ s: String) { message = s }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: L("Налаштування", "Settings"), back: model.back)

            Card(title: L("MQTT-брокер", "MQTT broker"), icon: "server.rack") {
                HStack(spacing: 8) {
                    Field(label: L("Адреса", "Host"), text: $model.draft.host, prompt: "192.168.1.10")
                    Field(label: L("Порт", "Port"), text: $model.draft.port, prompt: "1883").frame(width: 72)
                }
                HStack(spacing: 8) {
                    Field(label: L("Логін", "Username"), text: $model.draft.username, prompt: L("необов’язково", "optional"))
                    Field(label: L("Пароль", "Password"), text: $model.draft.password, prompt: L("необов’язково", "optional"), secure: true)
                    Field(label: L("Префікс", "Prefix"), text: $model.draft.prefix, prompt: "hb").frame(width: 56)
                }
            }

            stationsCard

            Card(title: L("Сповіщення", "Notifications"), icon: "bell") {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Низький заряд", "Low battery")).font(.system(size: 12))
                        Text(L("коли станція розряджається до порогу", "when a discharging station reaches a level"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SwitchView(isOn: model.draft.alertsOn) { model.draft.alertsOn = $0 }
                }
                if model.draft.alertsOn {
                    Field(label: L("Пороги, %", "Levels, %"), text: $model.draft.thresholds, prompt: "30, 15")
                }
                Divider().opacity(0.5)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Перед відключенням за графіком", "Before a scheduled outage")).font(.system(size: 12))
                        Text(L("і чи вистачить заряду", "and whether the charge will last")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SwitchView(isOn: model.draft.planOn) { model.draft.planOn = $0 }
                }
                if model.draft.planOn {
                    Field(label: L("За скільки хвилин", "Minutes before"), text: $model.draft.planMinutes, prompt: "30")
                }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Коли графік змінюється", "When the schedule changes")).font(.system(size: 12))
                        Text(L("що саме змінилося для твоєї черги", "what exactly changed for your queue")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SwitchView(isOn: model.draft.planChanges) { model.draft.planChanges = $0 }
                }
                Text(L("Сповіщення про зникнення й появу світла працюють завжди.", "Power outage / power back notifications are always on."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Card(title: L("Загальне", "General"), icon: "gearshape") {
                Chips(items: [(L("Темна", "Dark"), "dark"), (L("Світла", "Light"), "light"), (L("Системна", "System"), "system")],
                      selection: $model.draft.theme)
                AutostartRow()
            }

            dataCard

            if let err = model.settingsError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.red)
            }

            HStack(spacing: 8) {
                Button("config.json") { model.onOpenConfig() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(L("Відкрити файл налаштувань у редакторі", "Open the config file in an editor"))
                Spacer()
                Button(L("Скасувати", "Cancel")) { model.back() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Зберегти", "Save")) { model.saveSettings() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
        .frame(width: 312, alignment: .leading)
    }

    // MARK: stations

    private var stationsCard: some View {
        Card(title: L("Станції", "Stations"), icon: "bolt.batteryblock") {
            ForEach($model.draft.stations) { $s in
                StationEditor(station: $s, index: model.draft.stations.firstIndex(where: { $0.id == s.id }) ?? 0,
                              canDelete: model.draft.stations.count > 1,
                              verify: model.verify[s.id],
                              check: { model.check(s) },
                              delete: { model.draft.stations.removeAll { $0.id == s.id } })
            }
            Button {
                model.draft.stations.append(StationDraft())
            } label: {
                Label(L("Додати станцію", "Add station"), systemImage: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            discovery
        }
    }

    @ViewBuilder
    private var discovery: some View {
        let known = Set(model.draft.stations.map { $0.sn.trimmingCharacters(in: .whitespaces) })
        let fresh = model.found.filter { !known.contains($0.sn) }
        if !fresh.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Знайдено в мережі", "Found on the network"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(fresh, id: \.sn) { f in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.sn).font(.system(size: 12, design: .monospaced))
                            Text("\(f.ip) · \(Fmt.ago(Date(timeIntervalSince1970: f.seen)))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Додати", "Add")) { model.addFound(f) }.controlSize(.small)
                    }
                }
                Text(L("Токен однаково треба взяти із застосунку Jackery.", "You still need the token from the Jackery app."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(9)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else if model.found.isEmpty {
            Text(L("Автопошук бачить станції, підключені до локального Mosquitto (scripts/setup-mosquitto.sh).",
                   "Discovery sees stations connected to a local Mosquitto (scripts/setup-mosquitto.sh)."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: data

    private var dataCard: some View {
        Card(title: L("Дані", "Data"), icon: "internaldrive") {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Історія, журнал відключень, модель ККД", "History, outage log, efficiency model")).font(.system(size: 12))
                    Text(L("займають \(Fmt.bytes(model.dataSize)) · ~/.config/jackery-bar", "\(Fmt.bytes(model.dataSize)) · ~/.config/jackery-bar"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
            }
            if model.confirmClear {
                ConfirmBox(text: L("Видалити всю історію, журнал відключень і модель ККД для всіх станцій? Налаштування залишаться. Скасувати це неможливо.",
                                   "Delete all history, the outage log and the efficiency model for every station? Settings stay. This can’t be undone."),
                           confirm: L("Видалити", "Delete"),
                           onCancel: { model.confirmClear = false },
                           onConfirm: { model.clearData() })
            } else if model.cleared {
                Label(L("Дані очищено", "Data cleared"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Palette.green)
            } else {
                Button {
                    model.confirmClear = true
                } label: {
                    Text(L("Очистити всі дані…", "Clear all data…")).foregroundStyle(Palette.red)
                }
                .controlSize(.small)
            }
        }
    }
}

private struct StationEditor: View {
    @Binding var station: StationDraft
    let index: Int
    let canDelete: Bool
    let verify: PanelModel.VerifyState?
    let check: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Field(label: L("Назва", "Name"), text: $station.name, prompt: L("напр. Дім", "e.g. Home"))
                if canDelete {
                    Button(action: delete) {
                        Image(systemName: "trash").font(.system(size: 11))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("Прибрати станцію (її історія залишиться на диску)", "Remove station (its history stays on disk)"))
                    .padding(.top, 14)
                }
            }
            Field(label: L("Серійний номер", "Serial number"), text: $station.sn, prompt: "HS2C…", mono: true)
            HStack(alignment: .bottom, spacing: 8) {
                Field(label: L("Токен", "Token"), text: $station.token, prompt: L("із застосунку Jackery", "from the Jackery app"), secure: true)
                Button(L("Перевірити", "Check"), action: check)
                    .controlSize(.small)
                    .disabled(station.sn.isEmpty || station.token.isEmpty || verify == .checking)
                    .padding(.bottom, 3)
            }
            if let verify { verifyLabel(verify) }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Ємність автоматично", "Auto capacity")).font(.system(size: 12))
                    Text(L("2.52 кВт·год × (1 + дод. батареї)", "2.52 kWh × (1 + extra batteries)")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                SwitchView(isOn: station.capacityAuto) { station.capacityAuto = $0 }
            }
            if !station.capacityAuto {
                Field(label: L("Ємність, кВт·год", "Capacity, kWh"), text: $station.capacityKWh, prompt: "5.04")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func verifyLabel(_ v: PanelModel.VerifyState) -> some View {
        switch v {
        case .checking:
            Label(L("Перевіряю…", "Checking…"), systemImage: "hourglass").font(.system(size: 11)).foregroundStyle(.secondary)
        case .done(.ok):
            Label(L("Станція відповіла, токен вірний", "Station answered, token is correct"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(Palette.green)
        case .done(.wrongToken):
            Label(L("Невірний токен", "Wrong token"), systemImage: "xmark.octagon.fill").font(.system(size: 11)).foregroundStyle(Palette.red)
        case .done(.noAnswer):
            Label(L("Станція не відповіла: перевір серійний номер і MQTT у застосунку Jackery",
                    "No answer: check the serial number and MQTT in the Jackery app"), systemImage: "questionmark.circle")
                .font(.system(size: 11)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
        case .done(.notConnected):
            Label(L("Немає зв’язку з брокером: спершу збережи налаштування брокера", "Not connected to the broker: save the broker settings first"),
                  systemImage: "wifi.exclamationmark")
                .font(.system(size: 11)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Launch-at-login switch. Applies immediately (it's a system setting, not part of config.json).
private struct AutostartRow: View {
    @State private var on = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Запускати при вході", "Launch at login")).font(.system(size: 12))
                Text(L("відкривати JackeryBar після входу в macOS", "open JackeryBar when you log in to macOS"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            SwitchView(isOn: Snapshot.active || on, set: set)
        }
    }

    private func set(_ v: Bool) {
        do {
            if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("JackeryBar login item: \(error)")
        }
        on = SMAppService.mainApp.status == .enabled
    }
}

struct Field: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var secure = false
    var mono = false
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                Group {
                    if Snapshot.active {
                        Text(text.isEmpty ? prompt : (secure ? String(repeating: "•", count: 10) : text))
                            .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if secure && !reveal {
                        SecureField("", text: $text, prompt: Text(prompt))
                    } else {
                        TextField("", text: $text, prompt: Text(prompt))
                    }
                }
                .textFieldStyle(.plain)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                if secure {
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(reveal ? L("Сховати", "Hide") : L("Показати", "Show"))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.08)))
        }
    }
}
