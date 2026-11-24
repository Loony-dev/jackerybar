// Smaller views: chip grid, plan-vs-fact card, smart plugs / CT meters card.

import SwiftUI

/// Selectable chips laid out in a grid (for choices that don't fit one row).
struct ChipGrid<T: Hashable>: View {
    let items: [(String, T)]
    @Binding var selection: T
    var columns = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                let (label, value) = items[i]
                Button { selection = value } label: {
                    Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(selection == value ? Color.primary.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == value ? .primary : .secondary)
            }
        }
    }
}

/// "Schedule vs reality" for the last 7 days.
struct PlanAccuracyCard: View {
    let a: PlanAccuracy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("Графік vs факт", "Plan vs reality"), systemImage: "checklist").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let m = a.match {
                    Text(L("збіг \(Int((m * 100).rounded()))%", "\(Int((m * 100).rounded()))% match"))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(m >= 0.8 ? Palette.green : m >= 0.5 ? Palette.amber : Palette.red)
                }
            }
            Grid3 {
                StatCell(title: L("За графіком", "Planned"), value: hours(a.plannedHours))
                StatCell(title: L("Фактично", "Actual"), value: hours(a.actualHours))
                StatCell(title: L("Збіглося", "Matched"), value: hours(a.matchedHours))
                StatCell(title: L("Вимикали", "Went off"), value: delay(a.startDelayMin).0, caption: delay(a.startDelayMin).1)
                StatCell(title: L("Вмикали", "Came back"), value: delay(a.endDelayMin).0, caption: delay(a.endDelayMin).1)
                StatCell(title: L("Позапланово", "Unplanned"), value: hours(a.unplannedHours), caption: L("без графіка", "not scheduled"))
            }
            if a.sparedHours >= 0.25 {
                Text(L("За графіком світла не мало бути ще \(hours(a.sparedHours)), але його не вимикали.",
                       "Another \(hours(a.sparedHours)) was scheduled off, but the power stayed on."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(L("Порівняння графіка твоєї черги з відключеннями, які бачила станція, за \(a.days) днів.",
                   "Your queue’s schedule against the outages the station saw, over \(a.days) days."))
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func hours(_ h: Double) -> String { h < 0.02 ? L("0 год", "0 h") : Fmt.duration(h) }

    /// (value, caption): "+12 хв" / "пізніше".
    private func delay(_ m: Double?) -> (String, String) {
        guard let m else { return ("—", L("немає даних", "no data")) }
        let r = Int(m.rounded())
        if abs(r) < 2 { return (L("вчасно", "on time"), L("за графіком", "as planned")) }
        return r > 0 ? (L("+\(r) хв", "+\(r) min"), L("пізніше графіка", "after the plan")) : (L("−\(-r) хв", "−\(-r) min"), L("раніше графіка", "before the plan"))
    }
}

/// Smart plugs and CT meters attached to the station.
struct DevicesCard: View {
    let hub: Hub
    let st: Station

    var body: some View {
        let plugs = st.plugs.values.sorted { $0.displayName < $1.displayName }
        let meters = st.meters.values.sorted { $0.sn < $1.sn }
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Пристрої", "Devices"), systemImage: "powerplug").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(meters, id: \.sn) { m in
                HStack {
                    Image(systemName: "gauge.with.needle").foregroundStyle(.blue).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Лічильник (CT)", "Meter (CT)")).font(.system(size: 12))
                        Text(m.online ? m.sn : L("не на зв’язку", "offline")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let p = m.gridPower {
                        Text((p >= 0 ? L("з мережі ", "import ") : L("у мережу ", "export ")) + Fmt.watts(abs(p)))
                            .font(.system(size: 12)).monospacedDigit()
                    }
                }
            }
            ForEach(plugs, id: \.sn) { p in
                HStack {
                    Image(systemName: "poweroutlet.type.f").foregroundStyle(p.isOn == true ? Palette.green : .secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.displayName).font(.system(size: 12)).lineLimit(1)
                        Text(p.isLocal ? (p.energyKWh.map { Fmt.energy(kWh: $0) } ?? p.sn) : L("керування — у застосунку Jackery", "control in the Jackery app"))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.watts(p.power ?? 0)).font(.system(size: 12)).monospacedDigit()
                    if p.pendingOn != nil { ProgressView().controlSize(.mini) }
                    SwitchView(isOn: p.pendingOn ?? (p.isOn ?? false)) { on in hub.sendPlug(p, on: on, of: st) }
                        .disabled(!p.isLocal || !p.online || p.pendingOn != nil)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Shown on the main page while macOS blocks JackeryBar's notifications.
struct NotificationsBlockedBanner: View {
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash.fill").foregroundStyle(Palette.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Сповіщення вимкнені в macOS", "Notifications are off in macOS")).font(.system(size: 12, weight: .semibold))
                Text(L("не прийде ні про світло, ні про заряд", "no alerts about power or charge"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(L("Увімкнути", "Turn on"), action: open).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Palette.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
