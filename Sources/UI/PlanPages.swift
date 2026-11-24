// Planned outages (ГПВ): main-page card, schedule page (plan vs. what really happened), queue picker
// with address search.

import SwiftUI

private extension PlanForecast {
    var verdict: String {
        if runtimeHours.isInfinite { return L("заряду вистачить", "the battery will last") }
        return enough
            ? L("заряду вистачить: ~\(Fmt.duration(runtimeHours))", "battery lasts: ~\(Fmt.duration(runtimeHours))")
            : L("не вистачить: ~\(Fmt.duration(runtimeHours)) з \(Fmt.duration(outageHours))",
                "not enough: ~\(Fmt.duration(runtimeHours)) of \(Fmt.duration(outageHours))")
    }
}

private func span(_ o: PlannedOutage) -> String { "\(Fmt.clock(o.start.timeIntervalSince1970))–\(Fmt.clock(o.end.timeIntervalSince1970))" }

private func dayLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return L("сьогодні", "today") }
    if cal.isDateInTomorrow(d) { return L("завтра", "tomorrow") }
    return Fmt.day(d.timeIntervalSince1970, "EE, d MMM")
}

// MARK: - Main-page card

struct PlanCard: View {
    let hub: Hub
    let st: Station
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let now = Date()
        let region = st.config.scheduleRegion
        let schedule = region.flatMap { hub.schedules.schedule($0) }
        let next = hub.currentOrNextPlan(for: st, now: now)
        let inOutage = next.map { $0.contains(now) } ?? false
        let fc = next.flatMap { st.forecast($0, plan: hub.plan(for: st), now: now) }

        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 15))
                    .foregroundStyle(inOutage ? Palette.red : Palette.amber)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(L("Графік", "Schedule")).font(.system(size: 13, weight: .semibold))
                        if let q = st.config.queue {
                            Text(L("· черга \(q)", "· queue \(q)")).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        if let q = st.config.queue, let r = region, !hub.schedules.disagreements(r, group: q).isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Palette.amber)
                                .help(L("Джерела графіка розходяться — деталі на сторінці графіка", "Schedule sources disagree — see the schedule page"))
                        }
                        if schedule?.isEmergency == true {
                            Text(L("аварійні", "emergency")).font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Palette.red.opacity(0.2), in: Capsule()).foregroundStyle(Palette.red)
                        }
                    }
                    Group {
                        if st.config.queue == nil {
                            Text(L("Обери свою чергу, щоб бачити графік", "Pick your queue to see the schedule"))
                        } else if schedule == nil {
                            Text(hub.schedules.lastError[region ?? ""] ?? L("Завантажую графік…", "Loading schedule…"))
                        } else if let next {
                            Text(inOutage
                                 ? L("за графіком до \(Fmt.clock(next.end.timeIntervalSince1970)) · ще \(Fmt.span(next.end.timeIntervalSince(now)))",
                                     "scheduled until \(Fmt.clock(next.end.timeIntervalSince1970)) · \(Fmt.span(next.end.timeIntervalSince(now))) left")
                                 : L("наступне \(span(next))\(next.maybe ? " (можливе)" : "") · \(dayLabel(next.start) == L("сьогодні", "today") ? "через \(Fmt.span(next.start.timeIntervalSince(now)))" : dayLabel(next.start))",
                                     "next \(span(next))\(next.maybe ? " (possible)" : "") · \(dayLabel(next.start) == "today" ? "in \(Fmt.span(next.start.timeIntervalSince(now)))" : dayLabel(next.start))"))
                        } else {
                            Text(L("відключень не заплановано", "no outages planned"))
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.85)
                    if let fc {
                        Label(fc.verdict, systemImage: fc.enough ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(fc.enough ? Palette.green : Palette.red)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.primary.opacity(hover ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("Графік відключень", "Outage schedule"))
    }
}

// MARK: - Schedule page

struct SchedulePage: View {
    @ObservedObject var model: PanelModel
    let st: Station

    var body: some View {
        let _ = model.tick
        let hub = model.hub
        let region = st.config.scheduleRegion
        let schedule = region.flatMap { hub.schedules.schedule($0) }
        let regionName = region.flatMap { hub.schedules.region($0)?.localizedName } ?? L("Хмельницька", "Khmelnytskyi")
        let plan = hub.plan(for: st)
        let now = Date()

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: L("Графік відключень", "Outage schedule"),
                       subtitle: st.config.queue.map { L("\(regionName) · черга \($0)", "\(regionName) · queue \($0)") } ?? st.name,
                       icon: "calendar.badge.clock", tint: Palette.amber, back: model.back)

            if st.config.queue == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Щоб бачити графік, обери чергу цієї станції.", "Pick this station’s queue to see the schedule."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L("Обрати чергу…", "Pick queue…"), action: model.openQueuePicker).controlSize(.small)
                }
            } else if let schedule {
                if schedule.isEmergency {
                    Label(schedule.emergency?.note ?? L("Діють аварійні відключення: графік може не виконуватися.",
                                                        "Emergency outages in effect: the schedule may not apply."),
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let diffs = st.config.queue.map { hub.schedules.disagreements(region ?? "", group: $0) } ?? []
                if !diffs.isEmpty {
                    SourcesWarning(diffs: diffs, link: ScheduleService.operatorPage(region ?? "", fallback: schedule.sourceUrl))
                }
                if let last = st.lastScheduleChange, Date().timeIntervalSince(last.at) < 86400 {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("Графік змінено о \(Fmt.clock(last.at.timeIntervalSince1970))", "Schedule changed at \(Fmt.clock(last.at.timeIntervalSince1970))"),
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.amber)
                        ForEach(last.change.lines(today: RegionSchedule.dayString(), tomorrow: RegionSchedule.dayString(offset: 1)), id: \.self) { l in
                            Text(l).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                ForEach(schedule.dates, id: \.self) { date in
                    if let dayStart = RegionSchedule.date(date, "00:00") {
                        DayPlan(dayStart: dayStart, plan: plan, actual: st.grid.outages(from: dayStart.timeIntervalSince1970,
                                                                                       to: min(dayStart.timeIntervalSince1970 + 86400, now.timeIntervalSince1970)),
                                st: st, now: now)
                    }
                }
                HStack(spacing: 12) {
                    legend(Palette.amber, L("за графіком", "planned"))
                    legend(Palette.amber.opacity(0.35), L("можливе", "possible"))
                    legend(Palette.red, L("фактично", "actual"))
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(source(schedule))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L("Змінити чергу", "Change queue"), action: model.openQueuePicker).controlSize(.small)
                }
            } else {
                Text(hub.schedules.lastError[region ?? ""] ?? L("Завантажую графік…", "Loading schedule…"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 12, height: 6); Text(t) }
    }

    private func source(_ s: RegionSchedule) -> String {
        let when = s.updated.map { Fmt.day($0.timeIntervalSince1970, "dd.MM HH:mm") } ?? "—"
        let host = URL(string: s.sourceUrl)?.host ?? s.provider
        if s.feed == "hoe" {
            return L("Джерело: публікації \(host), розібрані напряму · перевірено \(when). Графік оператора може змінюватися протягом дня.",
                     "Source: \(host) posts, read directly · checked \(when). The operator may change the schedule during the day.")
        }
        let via = s.feed == "frankov" ? "khm_outage_parser" : "Koly Ye"
        return L("Джерело: \(host) через \(via) · оновлено \(when). Графік оператора може змінюватися протягом дня.",
                 "Source: \(host) via \(via) · updated \(when). The operator may change the schedule during the day.")
    }
}

/// One day: 24 h bar with planned (amber) and actual (red) outages, then the list with forecasts.
private struct DayPlan: View {
    let dayStart: Date
    let plan: [PlannedOutage]
    let actual: [(start: Double, end: Double)]
    let st: Station
    let now: Date

    var body: some View {
        let dayEnd = dayStart.addingTimeInterval(86400)
        let items = plan.filter { $0.end > dayStart && $0.start < dayEnd }
        let total = items.filter { !$0.maybe }.reduce(0.0) { $0 + (min($1.end, dayEnd).timeIntervalSince(max($1.start, dayStart))) }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dayLabel(dayStart).capitalized(with: Lang.locale) + " · " + Fmt.day(dayStart.timeIntervalSince1970, "d MMMM"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(items.isEmpty ? L("без відключень", "no outages") : L("без світла \(Fmt.span(total))", "\(Fmt.span(total)) off"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                let w = geo.size.width
                let x: (Date) -> CGFloat = { d in w * CGFloat(min(max(d.timeIntervalSince(dayStart), 0), 86400) / 86400) }
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Color.primary.opacity(0.07)).frame(height: 12)
                    ForEach(items.indices, id: \.self) { i in
                        let o = items[i]
                        Rectangle().fill(o.maybe ? Palette.amber.opacity(0.35) : Palette.amber)
                            .frame(width: max(2, x(o.end) - x(o.start)), height: 12)
                            .offset(x: x(o.start))
                    }
                    ForEach(actual.indices, id: \.self) { i in
                        let a = actual[i]
                        Rectangle().fill(Palette.red)
                            .frame(width: max(2, x(Date(timeIntervalSince1970: a.end)) - x(Date(timeIntervalSince1970: a.start))), height: 4)
                            .offset(x: x(Date(timeIntervalSince1970: a.start)), y: 15)
                    }
                    if now > dayStart && now < dayEnd {
                        Rectangle().fill(Color.primary.opacity(0.8)).frame(width: 1.5, height: 20).offset(x: x(now), y: -1)
                    }
                }
                .clipShape(Rectangle())
            }
            .frame(height: 20)
            HStack(spacing: 0) {
                ForEach(["0", "6", "12", "18", "24"], id: \.self) { h in
                    Text(h).font(.system(size: 9)).foregroundStyle(.tertiary)
                    if h != "24" { Spacer() }
                }
            }
            ForEach(items.indices, id: \.self) { i in
                let o = items[i]
                let fc = o.end > now ? st.forecast(o, plan: plan, now: now) : nil
                HStack(spacing: 6) {
                    Circle().fill(o.contains(now) ? Palette.red : o.end <= now ? Color.primary.opacity(0.25) : Palette.amber)
                        .frame(width: 6, height: 6)
                    Text(span(o) + (o.maybe ? L(" (можливе)", " (possible)") : ""))
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(o.end <= now ? .secondary : .primary)
                    Text(Fmt.span(o.duration)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 4)
                    if let fc {
                        Image(systemName: fc.enough ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(fc.enough ? Palette.green : Palette.red)
                            .help(fc.verdict)
                        Text(fc.runtimeHours.isFinite ? "~\(Fmt.durationShort(fc.runtimeHours))" : "∞")
                            .font(.system(size: 11)).foregroundStyle(fc.enough ? Palette.green : Palette.red).monospacedDigit()
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Two feeds disagree about the queue: show both versions and a link to the operator's post.
private struct SourcesWarning: View {
    let diffs: [SourceDisagreement]
    let link: URL?

    var body: some View {
        let today = RegionSchedule.dayString(), tomorrow = RegionSchedule.dayString(offset: 1)
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Джерела графіка розходяться", "Schedule sources disagree"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.amber)
            ForEach(Array(Set(diffs.map(\.date))).sorted(), id: \.self) { date in
                let rows = diffs.filter { $0.date == date }
                let day = date == today ? L("Сьогодні", "Today") : date == tomorrow ? L("Завтра", "Tomorrow") : date
                VStack(alignment: .leading, spacing: 1) {
                    Text(day).font(.system(size: 11, weight: .medium))
                    Text("\(rows[0].primaryFeed) ✓: " + text(rows[0].primary)).font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(rows, id: \.secondaryFeed) { r in
                        Text("\(r.secondaryFeed): " + text(r.secondary)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .monospacedDigit()
            }
            HStack(alignment: .top) {
                Text(diffs[0].primaryFeed == "hoe.com.ua"
                     ? L("Головне джерело — публікація самого обленерго (✓); інші сервіси після оновлень протягом дня іноді помиляються.",
                         "The main source is the utility’s own post (✓); other services sometimes get intraday updates wrong.")
                     : L("Так буває після оновлень графіка протягом дня. Головним лишається \(diffs[0].primaryFeed) (✓); звір із публікацією оператора.",
                         "This happens after intraday updates. \(diffs[0].primaryFeed) (✓) stays the main source; compare with the operator’s post."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if let link {
                    Button(L("Відкрити \(link.host ?? "сайт")", "Open \(link.host ?? "site")")) { NSWorkspace.shared.open(link) }
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func text(_ s: [ScheduleChange.Span]) -> String {
        s.isEmpty ? L("без відключень", "no outages") : s.map(\.text).joined(separator: ", ")
    }
}

// MARK: - Queue picker (opened from Settings for one station)

struct QueuePage: View {
    @ObservedObject var model: PanelModel
    let st: Station

    var body: some View {
        let hub = model.hub
        let region = model.queueRegion
        let queue = st.config.scheduleRegion == region ? st.config.queue : nil
        let info = hub.schedules.region(region)
        let groups = info?.groups ?? hub.schedules.schedule(region)?.groups ?? ["1.1", "1.2", "2.1", "2.2", "3.1", "3.2", "4.1", "4.2", "5.1", "5.2", "6.1", "6.2"]

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: L("Черга відключень", "Outage queue"), subtitle: st.name,
                       icon: "calendar.badge.clock", tint: Palette.amber, back: model.back)

            Card(title: L("Область", "Region"), icon: "map") {
                if Snapshot.active || hub.schedules.index.isEmpty {
                    Text(info?.localizedName ?? L("Хмельницька", "Khmelnytskyi")).font(.system(size: 12))
                } else {
                    Picker("", selection: Binding(get: { region }, set: { r in
                        model.queueRegion = r
                        model.addressResults = []; model.addressSearched = false
                    })) {
                        ForEach(hub.schedules.index, id: \.id) { Text($0.localizedName).tag($0.id) }
                    }
                    .labelsHidden()
                }
            }

            Card(title: L("Черга", "Queue"), icon: "square.grid.3x2") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(groups, id: \.self) { g in
                        Button { model.pickQueue(g, region: region) } label: {
                            Text(g).font(.system(size: 12, weight: .medium)).monospacedDigit()
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                                .background(queue == g ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(queue == g ? .white : .primary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Text(L("Номер черги є на квитанції або на сайті обленерго.", "The queue number is on your bill or the utility’s site."))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    if st.config.queue != nil {
                        Button(L("Без черги", "None")) { model.pickQueue(nil, region: region); model.page = .main }.controlSize(.small)
                    }
                }
            }

            if region == "khmelnytskyi" {
                addressSearch
            }
        }
    }

    private var addressSearch: some View {
        Card(title: L("Знайти за адресою", "Find by address"), icon: "magnifyingglass") {
            HStack(spacing: 8) {
                Field(label: L("Населений пункт", "Settlement"), text: $model.addressQuery.settlement, prompt: "Хмельницький")
                Field(label: L("Будинок", "House"), text: $model.addressQuery.house, prompt: "12").frame(width: 64)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Field(label: L("Вулиця", "Street"), text: $model.addressQuery.street, prompt: L("напр. Проскурівська", "e.g. Proskurivska"))
                Button(L("Знайти", "Search")) { model.searchAddress() }
                    .controlSize(.small)
                    .disabled(model.addressQuery.street.trimmingCharacters(in: .whitespaces).isEmpty || model.addressLoading)
                    .padding(.bottom, 3)
            }
            if model.addressLoading {
                Label(L("Завантажую файли черг з hoe.com.ua…", "Downloading queue files from hoe.com.ua…"), systemImage: "arrow.down.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let err = model.addressError {
                Label(err, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Palette.amber)
            } else if model.addressSearched && model.addressResults.isEmpty {
                Text(L("Нічого не знайдено. Спробуй іншу форму назви вулиці.", "Nothing found. Try another spelling of the street."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            let results = model.addressResults
            if !results.isEmpty {
                if Set(results.map(\.queue)).count > 1 && results.allSatisfy(\.exactHouse) {
                    Text(L("У будинку кілька приєднань з різними чергами — уточни свою на квитанції або в обленерго.",
                           "The building has several connections with different queues — check yours on the bill or with the utility."))
                        .font(.system(size: 10)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(results) { r in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(r.street)").font(.system(size: 12)).lineLimit(1)
                                Text("\(r.settlement) · \(r.district)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(r.queue).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            Button(L("Обрати", "Pick")) { model.pickQueue(r.queue, region: "khmelnytskyi") }.controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Text(L("Пошук іде по офіційних файлах Хмельницькобленерго, адреса не надсилається нікуди.",
                   "Search runs over Khmelnytskoblenergo’s official files; your address isn’t sent anywhere."))
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
