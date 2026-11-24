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
    var smartOn = false
    var smartHours = "6"
    var tgOn = false
    var tgToken = ""
    var tgChat = ""
    var tariffDay = "4.32"
    var tariffNightOn = false
    var tariffNight = "2.16"
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
        smartOn = c.smart.enabled
        smartHours = String(format: "%g", c.smart.lookaheadHours)
        tgOn = c.telegram?.enabled ?? false
        tgToken = c.telegram?.token ?? ""
        tgChat = c.telegram?.chatId ?? ""
        tariffDay = String(format: "%g", c.price.day)
        tariffNightOn = c.price.night != nil
        tariffNight = String(format: "%g", c.price.night ?? c.price.day / 2)
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

        func number(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
        guard let hours = number(smartHours), (1...24).contains(hours) || !smartOn
        else { return fail("Розумна зарядка: дивитися вперед на 1–24 год", "Smart charging: look ahead 1–24 h") }
        guard let day = number(tariffDay), day >= 0 else { return fail("Тариф — число, напр. 4.32", "Tariff must be a number, e.g. 4.32") }
        let night = tariffNightOn ? number(tariffNight) : nil
        if tariffNightOn && night == nil { return fail("Нічний тариф — число, напр. 2.16", "Night tariff must be a number, e.g. 2.16") }
        if tgOn && (tgToken.trimmingCharacters(in: .whitespaces).isEmpty || tgChat.trimmingCharacters(in: .whitespaces).isEmpty) {
            return fail("Telegram: вкажи токен бота і chat id", "Telegram: enter the bot token and chat id")
        }

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
                               planAlerts: PlanAlertConfig(enabled: planOn, minutesBefore: minutes, changes: planChanges),
                               smartCharge: SmartChargeConfig(enabled: smartOn, lookaheadHours: hours),
                               telegram: TelegramConfig(enabled: tgOn, token: tgToken.trimmingCharacters(in: .whitespaces),
                                                        chatId: tgChat.trimmingCharacters(in: .whitespaces)),
                               tariff: TariffConfig(day: day, night: night)))
    }
}

struct SettingsError: Error {
    let message: String
    init(_ s: String) { message = s }
}

// MARK: - View

/// Settings title; pinned above the scrolling form.
struct SettingsHeader: View {
    @ObservedObject var model: PanelModel
    var body: some View { PageHeader(title: L("Налаштування", "Settings"), back: model.back) }
}

/// Error message and Cancel / Save; pinned below the scrolling form so they're always visible.
struct SettingsFooter: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = model.settingsError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
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
}

/// The form itself (cards only; header and footer are separate).
struct SettingsView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                if model.notificationsBlocked {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L("macOS блокує сповіщення JackeryBar", "macOS is blocking JackeryBar’s notifications"),
                              systemImage: "bell.slash.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.red)
                        Text(L("Системні налаштування → Сповіщення → JackeryBar → увімкни «Дозволити сповіщення».",
                               "System Settings → Notifications → JackeryBar → turn on “Allow notifications”."))
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(L("Відкрити налаштування macOS", "Open macOS settings"), action: model.openNotificationSettings)
                            .controlSize(.small)
                    }
                    .padding(9)
                    .background(Palette.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
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
                Text(L("Сповіщення про зникнення й появу світла та аварійні відключення працюють завжди.",
                       "Power outage / power back and emergency-outage notifications are always on."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Button(L("Надіслати тестові сповіщення", "Send test notifications")) {
                    // Blocked by macOS: sending would silently go nowhere, so open the switch instead.
                    if model.notificationsBlocked { model.openNotificationSettings() } else { model.onTestNotifications() }
                }
                    .controlSize(.small)
            }

            telegramCard
            smartChargeCard
            tariffCard

            Card(title: L("Загальне", "General"), icon: "gearshape") {
                Chips(items: [(L("Темна", "Dark"), "dark"), (L("Світла", "Light"), "light"), (L("Системна", "System"), "system")],
                      selection: $model.draft.theme)
                AutostartRow()
            }

            dataCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var telegramCard: some View {
        Card(title: "Telegram", icon: "paperplane") {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Дублювати сповіщення в Telegram", "Also send notifications to Telegram")).font(.system(size: 12))
                    Text(L("через твого власного бота (@BotFather → /newbot)", "through your own bot (@BotFather → /newbot)"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                SwitchView(isOn: model.draft.tgOn) { model.draft.tgOn = $0 }
            }
            if model.draft.tgOn {
                Field(label: L("Токен бота", "Bot token"), text: $model.draft.tgToken, prompt: "123456:ABC…", secure: true)
                HStack(alignment: .bottom, spacing: 8) {
                    Field(label: "Chat id", text: $model.draft.tgChat, prompt: L("напиши боту й натисни «Знайти»", "message the bot, then Find"), mono: true)
                    Button(L("Знайти", "Find"), action: model.findTelegramChat).controlSize(.small)
                        .disabled(model.draft.tgToken.isEmpty).padding(.bottom, 3)
                }
                HStack {
                    if let s = model.telegramStatus { Text(s).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    Button(L("Тест", "Test"), action: model.testTelegram).controlSize(.small)
                        .disabled(model.draft.tgToken.isEmpty || model.draft.tgChat.isEmpty)
                }
            }
        }
    }

    private var smartChargeCard: some View {
        Card(title: L("Розумна зарядка", "Smart charging"), icon: "bolt.badge.clock") {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Заряджати до 100% перед відключенням", "Charge to 100% before an outage")).font(.system(size: 12))
                    Text(L("якщо з поточним лімітом заряду не вистачить; після — повертає ліміт",
                           "if the current charge limit won’t be enough; sets it back afterwards"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                SwitchView(isOn: model.draft.smartOn) { model.draft.smartOn = $0 }
            }
            if model.draft.smartOn {
                Field(label: L("Дивитися вперед, год", "Look ahead, h"), text: $model.draft.smartHours, prompt: "6")
                Text(L("Змінює налаштування станції (ліміт заряду). Потрібна черга графіка; про кожну зміну прийде сповіщення.",
                       "Changes a station setting (charge limit). Needs a schedule queue; you get a notification for every change."))
                    .font(.system(size: 10)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tariffCard: some View {
        Card(title: L("Тариф", "Tariff"), icon: "hryvniasign.circle") {
            HStack(spacing: 8) {
                Field(label: L("Ціна, грн/кВт·год", "Price per kWh"), text: $model.draft.tariffDay, prompt: "4.32")
                if model.draft.tariffNightOn {
                    Field(label: L("Ніч 23–7", "Night 23–7"), text: $model.draft.tariffNight, prompt: "2.16")
                }
            }
            HStack {
                Text(L("Двозонний облік (ніч 23:00–7:00)", "Two-zone meter (night 23:00–7:00)")).font(.system(size: 12))
                Spacer()
                SwitchView(isOn: model.draft.tariffNightOn) { model.draft.tariffNightOn = $0 }
            }
            Text(L("Для статистики «Вартість»: скільки коштувала енергія з мережі.", "Used by the Cost statistics: what grid energy cost."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

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
                HStack {
                    Button(L("Експорт у CSV", "Export to CSV"), action: model.exportCSV).controlSize(.small)
                    Spacer()
                    Button {
                        model.confirmClear = true
                    } label: {
                        Text(L("Очистити всі дані…", "Clear all data…")).foregroundStyle(Palette.red)
                    }
                    .controlSize(.small)
                }
                if let s = model.exportStatus {
                    Text(s).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
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
