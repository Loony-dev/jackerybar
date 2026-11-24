// Settings page shown inside the popup instead of opening config.json in an editor.

import SwiftUI
import ServiceManagement

/// Editable, string-based copy of Config for the form.
struct SettingsDraft {
    var host = ""
    var port = "1883"
    var username = ""
    var password = ""
    var deviceSn = ""
    var token = ""
    var topicPrefix = "hb"
    var capacityAuto = true
    var capacityKWh = ""
    var theme = "dark"
    var language = "uk"
    // Not shown in the form, preserved on save.
    var moduleWh: Double?
    var smoothingSeconds: Double?
    var name: String?

    init() {}

    init(_ c: Config) {
        host = c.host
        port = String(c.port ?? 1883)
        username = c.username ?? ""
        password = c.password ?? ""
        deviceSn = c.deviceSn.contains("СЕРИЙНЫЙ") ? "" : c.deviceSn
        token = c.token.contains("ТОКЕН") ? "" : c.token
        topicPrefix = c.topicPrefix ?? "hb"
        capacityAuto = c.capacityWh == nil
        capacityKWh = c.capacityWh.map { String(format: "%.2f", $0 / 1000) } ?? ""
        theme = c.theme ?? "dark"
        language = c.language ?? "uk"
        moduleWh = c.moduleWh
        smoothingSeconds = c.smoothingSeconds
        name = c.name
    }

    /// Validates the form and builds a Config, or returns an error message.
    func build() -> Result<Config, SettingsError> {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return .failure(SettingsError(L("Вкажи адресу брокера", "Enter the broker address"))) }
        guard let port = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port)
        else { return .failure(SettingsError(L("Порт має бути числом від 1 до 65535", "Port must be a number from 1 to 65535"))) }
        let sn = deviceSn.trimmingCharacters(in: .whitespaces)
        guard !sn.isEmpty else { return .failure(SettingsError(L("Вкажи серійний номер станції", "Enter the station serial number"))) }
        let tok = token.trimmingCharacters(in: .whitespaces)
        guard !tok.isEmpty else { return .failure(SettingsError(L("Вкажи токен із застосунку Jackery", "Enter the token from the Jackery app"))) }
        var capWh: Double?
        if !capacityAuto {
            guard let kwh = Double(capacityKWh.replacingOccurrences(of: ",", with: ".")), kwh > 0
            else { return .failure(SettingsError(L("Ємність — число в кВт·год, наприклад 5.04", "Capacity must be in kWh, e.g. 5.04"))) }
            capWh = kwh * 1000
        }
        let prefix = topicPrefix.trimmingCharacters(in: .whitespaces)
        return .success(Config(host: host, port: port,
                               username: username.isEmpty ? nil : username,
                               password: password.isEmpty ? nil : password,
                               deviceSn: sn, token: tok,
                               topicPrefix: prefix.isEmpty ? "hb" : prefix,
                               capacityWh: capWh, moduleWh: moduleWh ?? 2520,
                               smoothingSeconds: smoothingSeconds,
                               theme: theme == "dark" ? nil : theme,
                               language: language, name: name))
    }
}

struct SettingsError: Error, ExpressibleByStringLiteral {
    let message: String
    init(stringLiteral s: String) { message = s }
    init(_ s: String) { message = s }
}

extension Config {
    /// Reads config.json without rejecting placeholder values (for the settings form).
    static func loadRaw() -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: Config.url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.url.path)
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button { model.closeSettings() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(L("Назад", "Back"))
                Text(L("Налаштування", "Settings")).font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            Card(title: L("MQTT-брокер", "MQTT broker"), icon: "server.rack") {
                HStack(spacing: 8) {
                    Field(label: L("Адреса", "Host"), text: $model.draft.host, prompt: "192.168.1.10")
                    Field(label: L("Порт", "Port"), text: $model.draft.port, prompt: "1883").frame(width: 72)
                }
                HStack(spacing: 8) {
                    Field(label: L("Логін", "Username"), text: $model.draft.username, prompt: L("необов’язково", "optional"))
                    Field(label: L("Пароль", "Password"), text: $model.draft.password, prompt: L("необов’язково", "optional"), secure: true)
                }
            }

            Card(title: L("Станція", "Station"), icon: "bolt.batteryblock") {
                Field(label: L("Серійний номер", "Serial number"), text: $model.draft.deviceSn, prompt: "HS2C…", mono: true)
                HStack(spacing: 8) {
                    Field(label: L("Токен", "Token"), text: $model.draft.token, prompt: L("із застосунку Jackery", "from the Jackery app"), secure: true)
                    Field(label: L("Префікс", "Prefix"), text: $model.draft.topicPrefix, prompt: "hb").frame(width: 72)
                }
            }

            Card(title: L("Батарея", "Battery"), icon: "battery.75percent") {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Ємність автоматично", "Auto capacity")).font(.system(size: 12))
                        Text(L("2.52 кВт·год × (1 + дод. батареї)", "2.52 kWh × (1 + extra batteries)")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if Snapshot.active { FakeSwitch(on: model.draft.capacityAuto) } else {
                        Toggle("", isOn: $model.draft.capacityAuto)
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                }
                if !model.draft.capacityAuto {
                    Field(label: L("Ємність, кВт·год", "Capacity, kWh"), text: $model.draft.capacityKWh, prompt: "5.04")
                }
            }

            Card(title: L("Загальне", "General"), icon: "gearshape") {
                if Snapshot.active {
                    FakeSegmented(options: [L("Темна", "Dark"), L("Світла", "Light"), L("Системна", "System")],
                                  selected: ["dark", "light", "system"].firstIndex(of: model.draft.theme) ?? 0)
                } else {
                Picker("", selection: $model.draft.theme) {
                    Text(L("Темна", "Dark")).tag("dark")
                    Text(L("Світла", "Light")).tag("light")
                    Text(L("Системна", "System")).tag("system")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                }
                AutostartRow()
            }

            if let err = model.settingsError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.36))
            }

            HStack(spacing: 8) {
                Button("config.json") { model.onOpenConfig() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(L("Відкрити файл налаштувань у редакторі", "Open the config file in an editor"))
                Spacer()
                Button(L("Скасувати", "Cancel")) { model.closeSettings() }
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
            if Snapshot.active { FakeSwitch(on: true) } else {
                Toggle("", isOn: Binding(get: { on }, set: set))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
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

private struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Field: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var secure = false
    var mono = false
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Group {
                    if Snapshot.active {
                        Text(text.isEmpty ? prompt : (secure ? String(repeating: "•", count: 10) : text))
                            .foregroundStyle(text.isEmpty ? .tertiary : .primary)
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
