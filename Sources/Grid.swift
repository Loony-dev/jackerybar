// Mains (grid) presence: outage detection, outage log (JSON), main-page card and history page.

import SwiftUI

extension Station {
    /// Is mains power present? From the station's own `ongridStat` (1 = on-grid, 0 = off-grid);
    /// if a firmware doesn't send it, power drawn from the grid also proves it's there.
    /// "0 W from grid" alone is NOT treated as an outage — the station may just not be using it.
    var gridPresent: Bool? {
        if let s = v("ongridStat") { return s >= 1 }
        if let g = gridNet, g > 5 { return true }
        return nil
    }
}

final class GridLog {
    struct Outage: Codable {
        var start: Double
        var end: Double?
        /// Start is only known approximately (the app was started during the outage).
        var approx: Bool?
        /// One-minute data captured while the 24 h history still covered this outage.
        var series: OutageSeries?
        var duration: Double { (end ?? Date().timeIntervalSince1970) - start }
    }

    func setSeries(_ s: OutageSeries, forStart start: Double) {
        if let i = outages.firstIndex(where: { $0.start == start }) { outages[i].series = s }
    }

    func outage(start: Double) -> Outage? { outages.first { $0.start == start } }

    private(set) var outages: [Outage] = []
    /// Debounced state: nil until known.
    private(set) var isOn: Bool?
    /// When the current state began, if known.
    private(set) var since: Double?
    /// When outage tracking started (before that nothing is known).
    private(set) var trackingSince: Double?

    /// Fired on a real change (not on the first reading after start): (isOn, the outage that just ended).
    var onChange: ((Bool, Outage?) -> Void)?

    private var candidate: Bool?
    private var candidateCount = 0
    private var candidateSince = 0.0
    static let keepDays = 90.0

    /// Feed every reading; the state flips after 2 agreeing readings (~10 s) to ignore blips.
    func update(_ present: Bool?, at t: Double = Date().timeIntervalSince1970) {
        guard let present else { return }
        if trackingSince == nil { trackingSince = t }
        if present == isOn { candidate = nil; return }
        if candidate != present { candidate = present; candidateCount = 0; candidateSince = t }
        candidateCount += 1
        guard candidateCount >= 2 else { return }
        let first = isOn == nil
        let when = candidateSince
        isOn = present
        candidate = nil

        if present {
            if let i = outages.indices.last, outages[i].end == nil {
                outages[i].end = when
                since = when
                if !first { onChange?(true, outages[i]) }
            } else {
                since = first ? outages.last?.end : when
                if !first { onChange?(true, nil) }
            }
        } else {
            if let last = outages.last, last.end == nil {
                since = last.start          // app restarted during an outage it already knew about
            } else {
                outages.append(Outage(start: when, end: nil, approx: first ? true : nil))
                since = when
                if !first { onChange?(false, nil) }
            }
        }
        trim()
    }

    private func trim() {
        let cutoff = Date().timeIntervalSince1970 - Self.keepDays * 86400
        outages.removeAll { ($0.end ?? .infinity) < cutoff }
    }

    /// Outages overlapping [from, to], clipped to it.
    func outages(from: Double, to: Double) -> [(start: Double, end: Double)] {
        let now = Date().timeIntervalSince1970
        return outages.compactMap { o in
            let s = max(o.start, from), e = min(o.end ?? now, to)
            return e > s ? (s, e) : nil
        }
    }

    func summary(from: Double, to: Double) -> (count: Int, total: Double, longest: Double) {
        let parts = outages(from: from, to: to)
        let total = parts.reduce(0) { $0 + ($1.end - $1.start) }
        return (parts.count, total, parts.map { $0.end - $0.start }.max() ?? 0)
    }

    // --- persistence

    private struct File: Codable { var v: Int; var trackingSince: Double?; var outages: [Outage] }

    func save(to url: URL) {
        guard let d = try? JSONEncoder().encode(File(v: 1, trackingSince: trackingSince, outages: outages)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    func load(from url: URL) {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return }
        outages = f.outages.sorted { $0.start < $1.start }
        trackingSince = f.trackingSince ?? outages.first?.start
        trim()
    }
}

extension Fmt {
    /// Duration in seconds → "2ч 14м".
    static func span(_ seconds: Double) -> String { duration(max(seconds, 60) / 3600) }

    static func day(_ t: Double, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = format
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

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
            HStack(spacing: 8) {
                Button { model.showOutages = false } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(L("Назад", "Back"))
                Image(systemName: "lightbulb.fill").foregroundStyle(Palette.amber)
                Text(L("Світло", "Power")).font(.system(size: 14, weight: .semibold))
                Spacer()
            }

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

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                Stat(title: L("Відключень", "Outages"), value: "\(week.count)")
                Stat(title: L("Без світла", "Without power"), value: week.count == 0 ? "—" : Fmt.span(week.total))
                Stat(title: L("Найдовше", "Longest"), value: week.count == 0 ? "—" : Fmt.span(week.longest))
            }
            Text(L("за останні 7 днів", "last 7 days")).font(.system(size: 10)).foregroundStyle(.tertiary)

            let recent = Array(log.outages.suffix(8).reversed())
            if !recent.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { i, o in
                        if i > 0 { Divider().opacity(0.5) }
                        OutageRow(o: o, usedKWh: st.series(for: o)?.stats(duration: o.duration).usedKWh) {
                            model.outageStart = o.start
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
                        Text(u < 1 ? L("\(Int((u * 1000).rounded())) Вт·год", "\(Int((u * 1000).rounded())) Wh") : String(format: L("%.2f кВт·год", "%.2f kWh"), u))
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

private struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
