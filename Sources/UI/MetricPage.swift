// Chart page for one metric: 1 h … 30 d, hover readout, min/avg/max and energy.

import SwiftUI

struct MetricPage: View {
    @ObservedObject var model: PanelModel
    let st: Station
    let metric: Metric

    private var ranges: [(String, TimeInterval)] {
        [(L("1 год", "1 h"), 3600), (L("6 год", "6 h"), 6 * 3600), (L("24 год", "24 h"), 86400),
         (L("7 дн", "7 d"), 7 * 86400), (L("30 дн", "30 d"), 30 * 86400)]
    }

    var body: some View {
        let _ = model.tick
        let now = Date().timeIntervalSince1970
        let from = now - model.range
        let tf = st.transform(for: metric)
        let pts = st.store.buckets(metric, from: from, to: now, count: 156, transform: tf)
        let dom = SeriesChart.domain(for: metric, points: pts, capacityKWh: st.capacityWh / 1000)
        let stats = st.store.stats(metric, from: from, to: now, transform: tf)
        let long = model.range > 86400
        let mid = from + (now - from) / 2

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: metric.title, subtitle: model.hub.stations.count > 1 ? st.name : nil,
                       icon: metric.icon, tint: metric.tint, back: model.back)

            Text(st.current(metric).map(metric.format) ?? "—")
                .font(.system(size: 34, weight: .light)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)

            Chips(items: ranges, selection: $model.range)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    AxisLabels(metric: metric, domain: dom)
                        .frame(width: 30, height: 150)
                    ZStack {
                        if pts.allSatisfy({ $0 == nil }) {
                            Text(L("немає даних за цей період", "no data for this period")).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        SeriesChart(points: pts, metric: metric, domain: dom, interactive: true, from: from, to: now)
                    }
                    .frame(height: 150)
                }
                HStack {
                    Text(long ? Fmt.day(from, "dd.MM") : Fmt.clock(from)); Spacer()
                    Text(long ? Fmt.day(mid, "dd.MM") : Fmt.clock(mid)); Spacer()
                    Text(L("зараз", "now"))
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .padding(.leading, 36)
            }
            .padding(.top, 14)
            .padding([.horizontal, .bottom], 12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let s = stats {
                Grid3 {
                    StatCell(title: L("Мін", "Min"), value: metric.format(s.min))
                    StatCell(title: L("Середнє", "Average"), value: metric.format(s.avg))
                    StatCell(title: L("Макс", "Max"), value: metric.format(s.max))
                    if let (posLabel, negLabel) = metric.energyLabels {
                        StatCell(title: posLabel, value: Fmt.energy(kWh: s.posKWh))
                        if !negLabel.isEmpty { StatCell(title: negLabel, value: Fmt.energy(kWh: s.negKWh)) }
                    }
                }
                if s.since > from + max(120, model.range * 0.02) {
                    Text(L("Дані є з \(Fmt.day(s.since, long ? "dd.MM HH:mm" : "HH:mm"))",
                           "Data since \(Fmt.day(s.since, long ? "dd.MM HH:mm" : "HH:mm"))"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if long {
                    Text(L("Понад 24 год показано 5-хвилинні середні.", "Beyond 24 h, 5-minute averages are shown."))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
