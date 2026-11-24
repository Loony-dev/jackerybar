// Daily statistics: energy per day and hours without power, for the last 7 or 30 days.

import SwiftUI

struct StatsPage: View {
    @ObservedObject var model: PanelModel
    let st: Station

    var body: some View {
        let _ = model.tick
        let days = st.store.daily(days: model.statsDays)
        let kinds = StatsKind.allCases.filter { $0 != .solar || st.pvSeen }
        let kind = kinds.contains(model.statsKind) ? model.statsKind : .consumed
        let bars = days.map { bar(for: $0, kind: kind) }
        let vals = bars.compactMap(\.value)
        let total = vals.reduce(0, +)
        let best = zip(bars, bars.indices).filter { $0.0.value != nil }.max { ($0.0.value ?? 0) < ($1.0.value ?? 0) }
        let first = days.first(where: \.hasData)?.dayStart

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: L("Статистика", "Statistics"), subtitle: model.hub.stations.count > 1 ? st.name : nil,
                       icon: "chart.bar.xaxis", tint: .teal, back: model.back)

            HStack {
                Chips(items: [(L("7 днів", "7 days"), 7), (L("30 днів", "30 days"), 30)], selection: $model.statsDays)
                Spacer()
            }
            Chips(items: kinds.map { ($0.title, $0) }, selection: $model.statsKind)

            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if vals.isEmpty {
                        Text(L("Даних поки немає: вони накопичуються з першого запуску",
                               "No data yet: it accumulates from the first run"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                    BarChart(bars: bars, tint: tint(kind), format: { format($0, kind) })
                }
                .frame(height: 140)
                HStack {
                    Text(Fmt.day(days.first?.dayStart ?? 0, "dd.MM")); Spacer(); Text(L("сьогодні", "today"))
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.top, 16)
            .padding([.horizontal, .bottom], 12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Grid3 {
                StatCell(title: L("Разом", "Total"), value: vals.isEmpty ? "—" : format(total, kind))
                StatCell(title: L("В середньому", "Daily avg"), value: vals.isEmpty ? "—" : format(total / Double(vals.count), kind))
                StatCell(title: L("Найбільше", "Highest"), value: best.map { format($0.0.value ?? 0, kind) } ?? "—",
                         caption: best.map { $0.0.caption } ?? "")
            }
            if let first, first > (days.first?.dayStart ?? 0) {
                Text(L("Дані є з \(Fmt.day(first, "d MMMM"))", "Data since \(Fmt.day(first, "d MMMM"))"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func bar(for d: DayEnergy, kind: StatsKind) -> BarChart.Bar {
        let caption = Fmt.day(d.dayStart, "EE, d MMM")
        let label = Fmt.day(d.dayStart, "d")
        switch kind {
        case .outage:
            // Hours without power, only for days the outage log was tracking.
            guard let since = st.grid.trackingSince, d.dayStart + 86400 > since else { return .init(label: label, value: nil, caption: caption) }
            let s = st.grid.summary(from: d.dayStart, to: min(d.dayStart + 86400, Date().timeIntervalSince1970))
            return .init(label: label, value: s.total / 3600, caption: caption)
        default:
            guard d.hasData else { return .init(label: label, value: nil, caption: caption) }
            let v: Double = switch kind {
            case .consumed: d.consumed
            case .discharged: d.discharged
            case .imported: d.imported
            case .solar: d.solar
            case .outage: 0
            }
            return .init(label: label, value: v, caption: caption)
        }
    }

    private func format(_ v: Double, _ kind: StatsKind) -> String {
        kind == .outage ? (v < 0.01 ? L("0 год", "0 h") : Fmt.duration(v)) : Fmt.energy(kWh: v)
    }

    private func tint(_ kind: StatsKind) -> Color {
        switch kind {
        case .consumed: .purple
        case .discharged: Palette.discharge
        case .imported: .blue
        case .outage: Palette.red
        case .solar: Palette.amber
        }
    }
}
