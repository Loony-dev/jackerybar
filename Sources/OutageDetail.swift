// Per-outage statistics and charts.

import SwiftUI

/// One-minute series captured for an outage, stored inside the outage log so stats survive
/// after the 24 h metric history has rolled over.
struct OutageSeries: Codable {
    var t0: Double
    var step: Double
    var ac: [Double?]
    var bat: [Double?]
    var soc: [Double?]
    var temp: [Double?]

    var count: Int { ac.count }
}

struct OutageStats {
    var duration: Double
    var consumedKWh: Double        // delivered to the AC socket
    var usedKWh: Double            // taken out of the battery
    var chargedKWh: Double         // put into the battery (e.g. solar) during the outage
    var loadMin: Double?, loadAvg: Double?, loadMax: Double?
    var dischargeMax: Double?, dischargeAvg: Double?
    var socStart: Double?, socEnd: Double?, socMin: Double?
    var tempMin: Double?, tempMax: Double?
    var coverage: Double           // share of minutes with data

    var socDrop: Double? { socStart.flatMap { s in socEnd.map { s - $0 } } }
    var efficiency: Double? { usedKWh > 0.01 ? min(1, consumedKWh / usedKWh) : nil }
    var socPerHour: Double? {
        guard let d = socDrop, duration > 600 else { return nil }
        return d / (duration / 3600)
    }
}

extension OutageSeries {
    func stats(duration: Double) -> OutageStats {
        let h = step / 3600
        func vals(_ a: [Double?]) -> [Double] { a.compactMap { $0 } }
        let ac = vals(self.ac), bat = vals(self.bat), soc = vals(self.soc), temp = vals(self.temp)
        let discharge = bat.filter { $0 < -5 }.map { -$0 }
        let socFirst = self.soc.first(where: { $0 != nil }) ?? nil
        let socLast = self.soc.last(where: { $0 != nil }) ?? nil
        return OutageStats(
            duration: duration,
            consumedKWh: ac.reduce(0) { $0 + max(0, $1) * h } / 1000,
            usedKWh: bat.reduce(0) { $0 + max(0, -$1) * h } / 1000,
            chargedKWh: bat.reduce(0) { $0 + max(0, $1) * h } / 1000,
            loadMin: ac.min(), loadAvg: ac.isEmpty ? nil : ac.reduce(0, +) / Double(ac.count), loadMax: ac.max(),
            dischargeMax: discharge.max(),
            dischargeAvg: discharge.isEmpty ? nil : discharge.reduce(0, +) / Double(discharge.count),
            socStart: socFirst, socEnd: socLast, socMin: soc.min(),
            tempMin: temp.min(), tempMax: temp.max(),
            coverage: count == 0 ? 0 : Double(self.ac.filter { $0 != nil }.count) / Double(count)
        )
    }
}

extension Station {
    /// Builds a one-minute series for an outage from the 24 h metric history.
    func buildSeries(for o: GridLog.Outage) -> OutageSeries? {
        let now = Date().timeIntervalSince1970
        let end = o.end ?? now
        let n = Int(ceil((end - o.start) / 60))
        guard n > 0 else { return nil }
        let to = o.start + Double(n) * 60
        func col(_ m: Metric) -> [Double?] { store.buckets(m, from: o.start, to: to, count: n) { $0 } }
        return OutageSeries(t0: o.start, step: 60, ac: col(.ac), bat: col(.battery), soc: col(.soc), temp: col(.temp))
    }

    /// Series for display: fresh from history while it still covers the outage, otherwise the saved copy.
    func series(for o: GridLog.Outage) -> OutageSeries? {
        let now = Date().timeIntervalSince1970
        if (o.end ?? now) > now - MetricStore.retention + 300, let s = buildSeries(for: o), s.ac.contains(where: { $0 != nil }) {
            return s
        }
        return o.series
    }

    /// Stores series snapshots for outages the history still covers (called with every save).
    func snapshotOutages() {
        let now = Date().timeIntervalSince1970
        for o in grid.outages where (o.end ?? now) > now - MetricStore.retention + 300 {
            if let s = buildSeries(for: o), s.ac.contains(where: { $0 != nil }) {
                grid.setSeries(s, forStart: o.start)
            }
        }
    }
}

/// Averages a series down to at most `max` points (for drawing).
func downsample(_ a: [Double?], to max: Int) -> [Double?] {
    guard a.count > max, max > 0 else { return a }
    return (0..<max).map { i in
        let lo = i * a.count / max, hi = (i + 1) * a.count / max
        let v = a[lo..<hi].compactMap { $0 }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
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
            HStack(spacing: 8) {
                Button { model.outageStart = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(L("Назад", "Back"))
                Image(systemName: "lightbulb.slash.fill").foregroundStyle(Palette.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Відключення", "Outage")).font(.system(size: 14, weight: .semibold))
                    Text(Fmt.day(outage.start, "d MMMM, HH:mm") + (outage.approx == true ? "≈" : "") + " – "
                         + (outage.end.map { Fmt.clock($0) } ?? L("зараз", "now")))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if outage.end == nil {
                    Text(L("триває", "ongoing")).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Palette.red.opacity(0.16), in: Capsule())
                        .foregroundStyle(Palette.red)
                }
            }

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

    private func kwh(_ v: Double) -> String { v < 1 ? L("\(Int((v * 1000).rounded())) Вт·год", "\(Int((v * 1000).rounded())) Wh") : String(format: L("%.2f кВт·год", "%.2f kWh"), v) }
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

private struct Grid3<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) { content }
    }
}

private struct Cell: View {
    let title: String, value: String, caption: String
    init(_ title: String, _ value: String, _ caption: String) { self.title = title; self.value = value; self.caption = caption }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(caption.isEmpty ? " " : caption).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
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
