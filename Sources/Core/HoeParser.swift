// Khmelnytskoblenergo's own schedule posts (hoe.com.ua), read directly.
//
// One news post per day ("Прогноз ГПВ на 24 листопада"). Inside, sections separated by <hr>,
// newest first. The bottom one is the base schedule ("Години відсутності електроенергії:"); later
// sections are intraday updates, usually "Додаткові години відсутності…" — hours ADDED to the base.
// Third-party feeds have been seen getting exactly these updates wrong, so we apply them ourselves:
// start from the base and replay the updates oldest → newest.

import Foundation

enum HoeParser {
    static let newsURL = URL(string: "https://hoe.com.ua/post/novini-kompaniji")!
    static let months = ["січня", "лютого", "березня", "квітня", "травня", "червня",
                         "липня", "серпня", "вересня", "жовтня", "листопада", "грудня"]
    static let shortMonths = ["січ", "лют", "бер", "кві", "тра", "чер", "лип", "сер", "вер", "жов", "лис", "гру"]

    struct Post: Equatable { var url: String; var title: String; var date: String }

    /// Schedule posts from the news list: (link, title, target date "yyyy-MM-dd"), newest first.
    static func posts(inNews html: String) -> [Post] {
        var out: [Post] = []
        let article = try! NSRegularExpression(pattern: #"<article[^>]*>(.*?)</article>"#, options: [.dotMatchesLineSeparators])
        let heading = try! NSRegularExpression(pattern: #"class="heading"[^>]*>\s*<a[^>]*href="(/post/[^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let published = try! NSRegularExpression(pattern: #"(\d{1,2})\s+(\S{3})\S*\s+(\d{4})"#)
        let ns = html as NSString
        for m in article.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let block = ns.substring(with: m.range(at: 1))
            let b = block as NSString
            guard let h = heading.firstMatch(in: block, range: NSRange(location: 0, length: b.length)) else { continue }
            let url = b.substring(with: h.range(at: 1))
            let title = unescape(strip(b.substring(with: h.range(at: 2)))).trimmingCharacters(in: .whitespacesAndNewlines)
            let footer = strip(block)
            var pubYear: Int?, pubMonth: Int?
            if let p = published.firstMatch(in: footer, range: NSRange(location: 0, length: (footer as NSString).length)) {
                let f = footer as NSString
                pubYear = Int(f.substring(with: p.range(at: 3)))
                let mon = f.substring(with: p.range(at: 2)).lowercased()
                pubMonth = shortMonths.firstIndex(where: { mon.hasPrefix($0) }).map { $0 + 1 }
            }
            guard isSchedule(title), let date = targetDate(title, pubYear: pubYear, pubMonth: pubMonth) else { continue }
            out.append(Post(url: url, title: title, date: date))
        }
        return out
    }

    static func isSchedule(_ title: String) -> Bool {
        let t = title.lowercased()
        return (t.contains("гпв") || t.contains("відключен") || t.contains("графік")) && !t.contains("обмежен")
    }

    /// "Прогноз ГПВ на 24 листопада" + publication year → "2026-11-24" (a December post about January → next year).
    static func targetDate(_ title: String, pubYear: Int?, pubMonth: Int?) -> String? {
        let t = title.lowercased()
        let re = try! NSRegularExpression(pattern: #"на\s+(\d{1,2})\s+([а-яіїєґ']+)"#)
        guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) else { return nil }
        let ns = t as NSString
        guard let day = Int(ns.substring(with: m.range(at: 1))),
              let month = months.firstIndex(of: ns.substring(with: m.range(at: 2))).map({ $0 + 1 }) else { return nil }
        var year = pubYear ?? RegionSchedule.kyivCalendar.component(.year, from: Date())
        if let pm = pubMonth, pm == 12, month == 1 { year += 1 }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: post body

    /// Group → intervals ("HH:mm"…"HH:mm") after applying every update in the post. nil if no base schedule found.
    static func parsePost(_ html: String) -> [String: [RegionSchedule.Interval]]? {
        guard let start = html.range(of: "class=\"post\"") else { return nil }
        var body = String(html[start.upperBound...])
        if let end = body.range(of: "</div>") { body = String(body[..<end.lowerBound]) }
        let sections = body.components(separatedBy: "<hr").map(sectionText).reversed()   // oldest first

        var current: [String: [Range<Int>]]? = nil
        for text in sections {
            let lower = text.lowercased()
            let lines = groupLines(text)
            let cutoff = cutoffMinutes(lower)
            let additive = lower.contains("додатков")
            let cancelled = lines.isEmpty && (lower.contains("не застосовуват") || lower.contains("скасован"))

            if cancelled {
                guard var cur = current else { current = [:]; continue }
                for (g, r) in cur { cur[g] = clip(r, before: cutoff ?? 0) }
                current = cur
            } else if additive, var cur = current {
                for (g, r) in lines { cur[g] = union((cur[g] ?? []) + r) }
                current = cur
            } else if !lines.isEmpty, !additive {
                // A full schedule: replaces everything (or only from the cutoff time on).
                if let cutoff, var cur = current {
                    let groups = lines.count >= 6 ? Set(cur.keys).union(lines.keys) : Set(lines.keys)
                    for g in groups {
                        cur[g] = union(clip(cur[g] ?? [], before: cutoff) + clip(lines[g] ?? [], from: cutoff))
                    }
                    current = cur
                } else if current == nil || lines.count >= 6 {
                    current = lines
                } else {
                    for (g, r) in lines { current![g] = r }
                }
            }
        }
        guard let result = current, !result.isEmpty else { return nil }
        return result.mapValues { $0.map { RegionSchedule.Interval(from: hm($0.lowerBound), to: hm($0.upperBound), type: "off") } }
    }

    private static func sectionText(_ html: String) -> String {
        var t = html
        for tag in ["<br", "</p>", "<p"] { t = t.replacingOccurrences(of: tag, with: "\n" + tag, options: .caseInsensitive) }
        return unescape(strip(t))
    }

    /// "Підчерга 4.2 – 07:00-12:00; 16:00-20:00." / "Підчерги 3.1, 3.2 – …" / "з 10:00 до 15:00" / "вимкнень не буде".
    static func groupLines(_ text: String) -> [String: [Range<Int>]] {
        var out: [String: [Range<Int>]] = [:]
        let line = try! NSRegularExpression(pattern: #"підчерг[аи]\s+([\d.,\s]+?)\s*[–—\-:]\s*(.+)"#, options: [.caseInsensitive])
        let span = try! NSRegularExpression(pattern: #"(\d{1,2})[:.](\d{2})\s*(?:[–—\-]|до)\s*(\d{1,2})[:.](\d{2})"#)
        for raw in text.components(separatedBy: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            let ns = s as NSString
            guard let m = line.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            let groups = ns.substring(with: m.range(at: 1)).split(whereSeparator: { $0 == "," || $0 == " " })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { $0.contains(".") }
            let rest = ns.substring(with: m.range(at: 2)) as NSString
            var ranges: [Range<Int>] = []
            for t in span.matches(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
                let v = (1...4).map { Int(rest.substring(with: t.range(at: $0))) ?? 0 }
                let a = v[0] * 60 + v[1]
                var b = v[2] * 60 + v[3]
                if b <= a { b = 24 * 60 }              // "22:00-00:00"
                if a < b, a < 24 * 60 { ranges.append(a..<min(b, 24 * 60)) }
            }
            for g in groups { out[g] = union((out[g] ?? []) + ranges) }
        }
        return out
    }

    /// "оновлено з 20:00" → 1200.
    static func cutoffMinutes(_ lower: String) -> Int? {
        let re = try! NSRegularExpression(pattern: #"оновлено\s+з\s+(\d{1,2})[:.](\d{2})"#)
        guard let m = re.firstMatch(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)) else { return nil }
        let ns = lower as NSString
        return (Int(ns.substring(with: m.range(at: 1))) ?? 0) * 60 + (Int(ns.substring(with: m.range(at: 2))) ?? 0)
    }

    static func union(_ r: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for x in r.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, x.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, x.upperBound)
            } else {
                out.append(x)
            }
        }
        return out
    }

    static func clip(_ r: [Range<Int>], before t: Int) -> [Range<Int>] {
        r.compactMap { $0.lowerBound < t ? $0.lowerBound..<min($0.upperBound, t) : nil }
    }

    static func clip(_ r: [Range<Int>], from t: Int) -> [Range<Int>] {
        r.compactMap { $0.upperBound > t ? max($0.lowerBound, t)..<$0.upperBound : nil }
    }

    static func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

    static func strip(_ s: String) -> String { s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression) }

    static func unescape(_ s: String) -> String {
        var t = s
        for (a, b) in [("&nbsp;", " "), ("&laquo;", "«"), ("&raquo;", "»"), ("&ndash;", "–"), ("&mdash;", "—"),
                       ("&rsquo;", "’"), ("&#39;", "'"), ("&quot;", "\""), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    // MARK: network

    /// Downloads the news list and the posts for today and tomorrow (Kyiv) and builds a schedule.
    static func fetch(session: URLSession, _ done: @escaping (RegionSchedule?) -> Void) {
        func get(_ url: URL, _ cb: @escaping (String?) -> Void) {
            session.dataTask(with: url) { d, r, _ in
                let ok = (r as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                cb(ok ? d.map { String(decoding: $0, as: UTF8.self) } : nil)
            }.resume()
        }
        get(newsURL) { news in
            guard let news else { DispatchQueue.main.async { done(nil) }; return }
            let wanted = [RegionSchedule.dayString(), RegionSchedule.dayString(offset: 1)]
            var picked: [Post] = []
            for p in posts(inNews: news) where wanted.contains(p.date) && !picked.contains(where: { $0.date == p.date }) { picked.append(p) }
            let emergency = emergencyNote(news)
            guard !picked.isEmpty else { DispatchQueue.main.async { done(nil) }; return }
            var days: [RegionSchedule.Day] = []
            let group = DispatchGroup()
            let lock = NSLock()
            for p in picked {
                guard let url = URL(string: "https://hoe.com.ua" + p.url) else { continue }
                group.enter()
                get(url) { html in
                    if let html, let g = parsePost(html) {
                        lock.lock(); days.append(.init(date: p.date, groups: g)); lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard !days.isEmpty else { done(nil); return }
                let iso = ISO8601DateFormatter()
                iso.timeZone = RegionSchedule.kyiv
                let now = iso.string(from: Date())
                done(RegionSchedule(id: "khmelnytskyi", provider: "khmelnytskoblenergo", sourceUrl: newsURL.absoluteString,
                                    fetchedAt: now, updatedAt: now, status: "ok",
                                    emergency: .init(active: emergency != nil, note: emergency, since: nil),
                                    days: days.sorted { $0.date < $1.date }, feed: "hoe"))
            }
        }
    }

    /// An emergency-outage announcement for today in the news list (title), if any.
    static func emergencyNote(_ news: String) -> String? {
        let today = RegionSchedule.dayString()
        let re = try! NSRegularExpression(pattern: #"class="heading"[^>]*>\s*<a[^>]*>(.*?)</a>.*?(\d{1,2})\s+(\S{3})\S*\s+(\d{4})"#, options: [.dotMatchesLineSeparators])
        let ns = news as NSString
        for m in re.matches(in: news, range: NSRange(location: 0, length: ns.length)) {
            let title = unescape(strip(ns.substring(with: m.range(at: 1)))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.lowercased().contains("аварійн") else { continue }
            let mon = ns.substring(with: m.range(at: 3)).lowercased()
            guard let mi = shortMonths.firstIndex(where: { mon.hasPrefix($0) }), let d = Int(ns.substring(with: m.range(at: 2))),
                  let y = Int(ns.substring(with: m.range(at: 4))) else { continue }
            if String(format: "%04d-%02d-%02d", y, mi + 1, d) == today { return title }
        }
        return nil
    }
}
