// Station control: AC outlet, charge/discharge limits, grid-port output limit, reboot.
// Uses the same local MQTT commands as Jackery's official Home Assistant integration.

import SwiftUI

struct ControlPage: View {
    @ObservedObject var model: PanelModel
    let st: Station

    var body: some View {
        let _ = model.tick
        let online = model.hub.isConnected && !st.isStale && !st.tokenRejected

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: L("Керування", "Control"), subtitle: st.name, icon: "slider.horizontal.3", tint: .accentColor, back: model.back)

            if !online {
                Label(L("Станція не на зв’язку: команди зараз не дійдуть.", "Station is offline: commands won’t reach it now."),
                      systemImage: "wifi.exclamationmark")
                    .font(.system(size: 11)).foregroundStyle(Palette.amber)
            }

            Card(title: L("Розетка AC", "AC outlet"), icon: "poweroutlet.type.f.fill") {
                let on = (st.v("swEps") ?? 1) >= 1
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(on ? L("Увімкнена", "On") : L("Вимкнена", "Off")).font(.system(size: 12))
                        Text(L("навантаження \(Fmt.watts(st.v("swEpsOutPw") ?? 0))", "load \(Fmt.watts(st.v("swEpsOutPw") ?? 0))"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    status("swEps")
                    SwitchView(isOn: on) { newValue in
                        if newValue { model.hub.send(.acOutlet(true), to: st) } else { model.confirming = .acOutlet(false) }
                    }
                    .disabled(!online || st.isPending("swEps"))
                }
                if model.confirming == .acOutlet(false) {
                    ConfirmBox(text: L("Вимкнути розетку AC? Усе, що до неї підключено, знеструмиться.",
                                       "Turn the AC outlet off? Everything plugged into it will lose power."),
                               confirm: L("Вимкнути", "Turn off"),
                               onCancel: { model.confirming = nil },
                               onConfirm: { model.confirming = nil; model.hub.send(.acOutlet(false), to: st) })
                }
            }

            Card(title: L("Ліміти батареї", "Battery limits"), icon: "battery.75percent") {
                limitRow(key: "socChgLimit", title: L("Заряджати до", "Charge up to"),
                         caption: L("вище станція не заряджає", "the station stops charging here"),
                         range: range("minSocChg", "maxSocChg", JackeryProtocol.Command.chargeRange), step: 5, unit: "%") { .chargeLimit($0) }
                Divider().opacity(0.5)
                limitRow(key: "socDischgLimit", title: L("Розряджати до", "Discharge down to"),
                         caption: L("недоторканний резерв", "reserve that stays untouched"),
                         range: range("minSocDischg", "maxSocDischg", JackeryProtocol.Command.dischargeRange), step: 5, unit: "%") { .dischargeLimit($0) }
            }

            if st.v("maxOutPw") != nil {
                Card(title: L("Мережевий порт", "Grid port"), icon: "bolt.horizontal.fill") {
                    limitRow(key: "maxOutPw", title: L("Макс. віддача", "Max output"),
                             caption: L("потужність на мережевому порту", "power on the grid port"),
                             range: JackeryProtocol.Command.maxOutputRange, step: 50, unit: L(" Вт", " W")) { .maxOutput($0) }
                }
            }

            Card(title: L("Станція", "Station"), icon: "bolt.batteryblock") {
                if model.confirming == .reboot {
                    ConfirmBox(text: L("Перезавантажити станцію? Вона ненадовго зникне зі зв’язку.",
                                       "Restart the station? It will be offline for a short while."),
                               confirm: L("Перезавантажити", "Restart"), destructive: false,
                               onCancel: { model.confirming = nil },
                               onConfirm: { model.confirming = nil; model.hub.send(.reboot, to: st) })
                } else {
                    Button(L("Перезавантажити станцію…", "Restart station…")) { model.confirming = .reboot }
                        .controlSize(.small)
                        .disabled(!online)
                }
            }

            Text(L("Команди йдуть локально через MQTT, як в офіційній інтеграції Jackery. Нове значення з’явиться, коли станція його підтвердить.",
                   "Commands go locally over MQTT, like Jackery’s official integration. The new value shows up once the station confirms it."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func range(_ minKey: String, _ maxKey: String, _ fallback: ClosedRange<Int>) -> ClosedRange<Int> {
        let lo = st.v(minKey).map { Int($0) } ?? fallback.lowerBound
        let hi = st.v(maxKey).map { Int($0) } ?? fallback.upperBound
        return lo < hi ? lo...hi : fallback
    }

    /// Stepper + "Apply" for a numeric setting; shows pending / failed state.
    @ViewBuilder
    private func limitRow(key: String, title: String, caption: String, range: ClosedRange<Int>, step: Int, unit: String,
                          command: @escaping (Int) -> JackeryProtocol.Command) -> some View {
        let current = st.v(key).map { Int($0.rounded()) }
        let shown = model.controlDraft[key] ?? current ?? range.lowerBound
        VStack(alignment: .leading, spacing: 6) {
            StepperRow(title: title, caption: caption, value: shown, range: range, step: step, unit: unit) {
                model.controlDraft[key] = $0
            }
            HStack {
                status(key)
                Spacer()
                if let d = model.controlDraft[key], d != current, !st.isPending(key) {
                    Button(L("Скинути", "Reset")) { model.controlDraft[key] = nil }.controlSize(.small)
                    Button(L("Застосувати", "Apply")) {
                        if model.hub.send(command(d), to: st) { model.controlDraft[key] = nil }
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private func status(_ key: String) -> some View {
        if st.isPending(key) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(L("чекаю підтвердження…", "waiting for the station…")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } else if st.failedCommand == key {
            Label(L("станція не підтвердила", "the station didn’t confirm"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 10)).foregroundStyle(Palette.amber)
        }
    }
}
