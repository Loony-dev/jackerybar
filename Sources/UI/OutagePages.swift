// Outage UI: the "Power" card on the main page, the week/outage list page and a page per outage.

import SwiftUI

// MARK: - Main-page card

struct GridCard: View {
    let log: GridLog
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let now = Date().timeIntervalSince1970
        let day = log.summary(from: now - 86400, to: now)
        let on = log.isOn
        let tint: Color = on == false ? Palette.red : on == true ? Palette.amber : .secondary

        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: on == false ? "lightbulb.slash.fill" : "lightbulb.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(on == nil ? L("Світло: визначаю…", "Power: detecting…") : on! ? L("Світло є", "Power is on") : L("Немає світла", "Power outage"))
                        .font(.system(size: 13, weight: .semibold))
                    if let s = log.since {
                        Text((on == false ? L("вже ", "for ") : "") + Fmt.span(now - s) + L(" · з ", " · since ") + Fmt.clock(s))
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(L("за добу", "24 h") + (day.count == 0 ? "" : L(" · \(day.count) відкл.", " · \(day.count) outages")))
                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                    Text(day.count == 0 ? L("без відключень", "no outages") : Fmt.span(day.total))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background((on == false ? Palette.red.opacity(hover ? 0.2 : 0.14) : Color.primary.opacity(hover ? 0.08 : 0.05)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("Історія відключень", "Outage history"))
    }
}

// MARK: - Outage history page

struct OutagesView: View {
    @ObservedObject var model: PanelModel
    let st: Station
    var log: GridLog { st.grid }

    var body: some View {
        let _ = model.tick
        let now = Date().timeIntervalSince1970
        let week = log.summary(from: now - 7 * 86400, to: now)
        let on = log.isOn

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: L("Світло", "Power"), subtitle: model.hub.stations.count > 1 ? st.name : nil,
                       icon: "lightbulb.fill", tint: Palette.amber, back: model.back)

            HStack(alignment: .firstTextBaseline) {
                Text(on == nil ? "—" : on! ? L("Є", "On") : L("Немає", "Off"))
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(on == false ? Palette.red : .primary)
                if let s = log.since {
                    Text((on == false ? L("вже ", "for ") : "") + Fmt.span(now - s))
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            WeekTimeline(log: log, now: now)

            Grid3 {
                StatCell(title: L("Відключень", "Outages"), value: "\(week.count)")
                StatCell(title: L("Без світла", "Without power"), value: week.count == 0 ? "—" : Fmt.span(week.total))
                StatCell(title: L("Найдовше", "Longest"), value: week.count == 0 ? "—" : Fmt.span(week.longest))
            }
            Text(L("за останні 7 днів", "last 7 days")).font(.system(size: 10)).foregroundStyle(.tertiary)

            let recent = Array(log.outages.suffix(8).reversed())
            if !recent.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { i, o in
                        if i > 0 { Divider().opacity(0.5) }
                        OutageRow(o: o, usedKWh: st.series(for: o)?.stats(duration: o.duration).usedKWh) {
                            model.open(.outage(o.start))
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text(L("Відключень поки не було", "No outages yet")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OutageRow: View {
    let o: GridLog.Outage
    let usedKWh: Double?
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Circle().fill(o.end == nil ? Palette.red : Color.primary.opacity(0.25)).frame(width: 6, height: 6)
                Text(Fmt.day(o.start, "dd.MM HH:mm") + (o.approx == true ? "≈" : "") + "–"
                     + (o.end.map { Fmt.clock($0) } ?? L("зараз", "now")))
                    .font(.system(size: 11.5)).monospacedDigit()
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.span(o.duration))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(o.end == nil ? Palette.red : .secondary)
                    // Energy taken from the battery during this outage.
                    if let u = usedKWh, u > 0.005 {
                        Text(Fmt.energy(kWh: u))
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
                            .lineLimit(1).fixedSize()
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
            .background(Color.primary.opacity(hover ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Seven rows (days), each a 24 h bar with outages in red.
private struct WeekTimeline: View {
    let log: GridLog
    let now: Double

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<7, id: \.self) { k in
                let dayStart = cal.date(byAdding: .day, value: -k, to: Date(timeIntervalSince1970: today))!.timeIntervalSince1970
                let dayEnd = dayStart + 86400
                HStack(spacing: 8) {
                    Text(k == 0 ? L("Сьогодні", "Today") : k == 1 ? L("Вчора", "Yesterday") : Fmt.day(dayStart, "EE, d"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    GeometryReader { geo in
                        let w = geo.size.width
                        // Green only where power was actually observed; unknown time (before tracking
                        // started, or later today) stays neutral.
                        let seenFrom = max(dayStart, log.trackingSince ?? now)
                        let seenTo = min(dayEnd, now)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            if seenTo > seenFrom {
                                Rectangle().fill(Palette.green.opacity(0.35))
                                    .frame(width: w * CGFloat((seenTo - seenFrom) / 86400))
                                    .offset(x: w * CGFloat((seenFrom - dayStart) / 86400))
                            }
                            ForEach(Array(log.outages(from: dayStart, to: min(dayEnd, now)).enumerated()), id: \.offset) { _, o in
                                Rectangle().fill(Palette.red)
                                    .frame(width: max(2, w * CGFloat((o.end - o.start) / 86400)))
                                    .offset(x: w * CGFloat((o.start - dayStart) / 86400))
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 8)
                }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: 60)
                ForEach(["0", "6", "12", "18", "24"], id: \.self) { h in
                    Text(h).font(.system(size: 9)).foregroundStyle(.tertiary)
                    if h != "24" { Spacer() }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Page

struct OutageDetailView: View {
    @ObservedObject var model: PanelModel
    let st: Station
    let outage: GridLog.Outage

    var body: some View {
        let _ = model.tick
        let now = Date().timeIntervalSince1970
        let end = outage.end ?? now
        let series = st.series(for: outage)
        let s = series?.stats(duration: outage.duration)

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: L("Відключення", "Outage"),
                       subtitle: Fmt.day(outage.start, "d MMMM, HH:mm") + (outage.approx == true ? "≈" : "") + " – "
                           + (outage.end.map { Fmt.clock($0) } ?? L("зараз", "now")),
                       icon: "lightbulb.slash.fill", tint: Palette.red, back: model.back,
                       trailing: outage.end == nil ? AnyView(
                           Text(L("триває", "ongoing")).font(.system(size: 11, weight: .semibold))
                               .padding(.horizontal, 8).padding(.vertical, 3)
                               .background(Palette.red.opacity(0.16), in: Capsule())
                               .foregroundStyle(Palette.red)) : nil)

            // Duration + SOC drop
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.span(outage.duration)).font(.system(size: 34, weight: .light)).monospacedDigit()
                if let a = s?.socStart, let b = s?.socEnd {
                    Text("\(Int(a.rounded()))% → \(Int(b.rounded()))%")
                        .font(.system(size: 15)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
            }
            if let a = s?.socStart, let b = s?.socEnd {
                SocDropBar(start: a, end: b, minSoc: st.minSoc)
            }

            if let s {
                Grid3 {
                    Cell(L("Спожито", "Consumed"), kwh(s.consumedKWh), L("приладами", "by devices"))
                    Cell(L("З батареї", "From battery"), kwh(s.usedKWh), s.socDrop.map { L("−\(Int($0.rounded()))% заряду", "−\(Int($0.rounded()))% charge") } ?? "")
                    Cell(L("ККД", "Efficiency"), s.efficiency.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", L("втрати \(kwh(max(0, s.usedKWh - s.consumedKWh)))", "losses \(kwh(max(0, s.usedKWh - s.consumedKWh)))"))
                    Cell(L("Навантаж. мін", "Min load"), w(s.loadMin), "")
                    Cell(L("Середнє", "Average"), w(s.loadAvg), "")
                    Cell(L("Пік", "Peak"), w(s.loadMax), "")
                    Cell(L("Витрата", "Drain"), s.socPerHour.map { String(format: L("%.1f%%/год", "%.1f%%/h"), $0) } ?? "—", L("заряду", "of charge"))
                    Cell(L("Розряд макс", "Max discharge"), w(s.dischargeMax), L("батарея", "battery"))
                    Cell(L("Темп.", "Temp."), tempRange(s), L("комірки", "cells"))
                    if s.chargedKWh > 0.01 { Cell(L("Підзаряджено", "Recharged"), kwh(s.chargedKWh), L("сонце", "solar")) }
                }
                footnote(s, now: now)
            } else {
                Text(L("Немає даних за це відключення: застосунок тоді не працював.", "No data for this outage: the app wasn’t running."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            if let series, series.ac.contains(where: { $0 != nil }) {
                ChartBlock(title: L("Навантаження", "Load"), metric: .ac, values: series.ac, from: outage.start, to: end, cap: 0)
                ChartBlock(title: L("Заряд", "Charge"), metric: .soc, values: series.soc, from: outage.start, to: end, cap: 0)
                ChartBlock(title: L("Батарея", "Battery"), metric: .battery, values: series.bat, from: outage.start, to: end, cap: 0)
            }
        }
    }

    private func kwh(_ v: Double) -> String { Fmt.energy(kWh: v) }
    private func w(_ v: Double?) -> String { v.map { Fmt.watts($0) } ?? "—" }
    private func tempRange(_ s: OutageStats) -> String {
        guard let a = s.tempMin, let b = s.tempMax else { return "—" }
        return abs(b - a) < 0.5 ? String(format: "%.0f °C", a) : String(format: "%.0f–%.0f °C", a, b)
    }

    @ViewBuilder
    private func footnote(_ s: OutageStats, now: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if outage.end == nil, let h = st.runtimeHours, h.isFinite {
                Label(L("Батареї вистачить ще на ~\(Fmt.duration(h)) — до \(Fmt.clock(now + h * 3600))", "Battery lasts ~\(Fmt.duration(h)) more — until \(Fmt.clock(now + h * 3600))"),
                      systemImage: "hourglass")
                    .foregroundStyle(Palette.amber)
            } else if let end = s.socEnd, let avg = s.dischargeAvg, avg > 5 {
                let left = max(0, end - st.minSoc) / 100 * st.capacityWh / avg
                Label(L("За такого навантаження вистачило б ще на ~\(Fmt.duration(left))", "At this load it would last ~\(Fmt.duration(left)) more"), systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
            if s.coverage < 0.9 {
                Label(L("Дані є за \(Int((s.coverage * 100).rounded()))% часу відключення", "Data covers \(Int((s.coverage * 100).rounded()))% of the outage"), systemImage: "info.circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11))
    }
}

private struct SocDropBar: View {
    let start: Double
    let end: Double
    let minSoc: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                // Reserve below the discharge limit.
                Rectangle().fill(Palette.red.opacity(0.25)).frame(width: w * minSoc / 100)
                // What was spent during the outage.
                Rectangle().fill(Palette.discharge.opacity(0.45))
                    .frame(width: w * max(0, start - end) / 100)
                    .offset(x: w * min(start, end) / 100)
                // What is left.
                Rectangle().fill(Palette.forSoc(end)).frame(width: w * min(start, end) / 100)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

/// Stat tile with a caption line.
private func Cell(_ title: String, _ value: String, _ caption: String) -> StatCell {
    StatCell(title: title, value: value, caption: caption)
}

private struct ChartBlock: View {
    let title: String
    let metric: Metric
    let values: [Double?]
    let from: Double
    let to: Double
    let cap: Double

    var body: some View {
        let pts = downsample(values, to: 156)
        let dom = SeriesChart.domain(for: metric, points: pts, capacityKWh: cap)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: metric.icon).font(.system(size: 10)).foregroundStyle(metric.tint)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(metric.axis(dom.lowerBound) + " … " + metric.axis(dom.upperBound))
                    .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
            }
            SeriesChart(points: pts, metric: metric, domain: dom, interactive: true, from: from, to: to)
                .frame(height: 64)
            HStack {
                Text(Fmt.clock(from)); Spacer(); Text(Fmt.clock(from + (to - from) / 2)); Spacer(); Text(Fmt.clock(to))
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(.top, 10).padding([.horizontal, .bottom], 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
