// Address → outage queue for Khmelnytskyi oblast, from the operator's own files.
//
// hoe.com.ua/page/pogodinni-vidkljuchennja links one XLSX per district (РЕМ):
//   /Content/Uploads/GPV6/xls/Черги_на_відключення_Летичівський_РЕМ_09102026.xlsx
// One sheet: "Населений пункт | Вулиця | Список будинків | Черга/підчерга", one row per street and queue.
// Files are downloaded once and parsed locally; the address you type never leaves the Mac.

import Foundation

struct AddressEntry: Codable, Equatable {
    var district: String
    var settlement: String
    var street: String
    var houses: [String]      // normalized: "10А", "53/1"
    var queue: String         // "1.1"
}

struct AddressMatch: Equatable, Identifiable {
    var district: String
    var settlement: String
    var street: String
    var queue: String
    /// The house matched exactly (false = the street has several queues, house not given/found).
    var exactHouse: Bool
    var id: String { "\(district)|\(settlement)|\(street)|\(queue)" }
}

final class AddressBook {
    static let pageURL = URL(string: "https://hoe.com.ua/page/pogodinni-vidkljuchennja")!
    static let cacheURL = Paths.dir.appendingPathComponent("addresses-khmelnytskyi.json")
    static let maxAge: TimeInterval = 7 * 86400

    /// Compact on-disk form: [[district, settlement, street, "h1,h2,…", queue], …].
    private struct Cache: Codable { var fetchedAt: Double; var files: [String]; var rows: [[String]] }

    private(set) var entries: [AddressEntry] = []
    private(set) var fetchedAt: Date?
    private(set) var files: [String] = []
    private(set) var loading = false

    private var cacheLoaded = false

    /// Reads the cached address list (lazily — only when the address search is used).
    func loadCache() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let d = try? Data(contentsOf: Self.cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d) else { return }
        entries = c.rows.compactMap { r in
            r.count == 5 ? AddressEntry(district: r[0], settlement: r[1], street: r[2],
                                        houses: r[3].split(separator: ",").map(String.init), queue: r[4]) : nil
        }
        fetchedAt = Date(timeIntervalSince1970: c.fetchedAt); files = c.files
    }

    func removeCache() {
        entries = []; files = []; fetchedAt = nil; cacheLoaded = false
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    var isStale: Bool { fetchedAt.map { Date().timeIntervalSince($0) > Self.maxAge } ?? true }

    /// Downloads and parses the district files (in the background). `done(error)` on main.
    func load(force: Bool = false, done: @escaping (String?) -> Void) {
        loadCache()
        guard force || isStale || entries.isEmpty else { done(nil); return }
        guard !loading else { done(nil); return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.download()
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let (files, entries)):
                    self.entries = entries; self.files = files; self.fetchedAt = Date()
                    let rows = entries.map { [$0.district, $0.settlement, $0.street, $0.houses.joined(separator: ","), $0.queue] }
                    if let d = try? JSONEncoder().encode(Cache(fetchedAt: Date().timeIntervalSince1970, files: files, rows: rows)) {
                        try? d.write(to: Self.cacheURL, options: .atomic)
                    }
                    done(nil)
                case .failure(let e):
                    done(self.entries.isEmpty ? e.localizedDescription : nil)
                }
            }
        }
    }

    private static func download() -> Result<([String], [AddressEntry]), Error> {
        do {
            let html = String(decoding: try fetch(pageURL), as: UTF8.self)
            let links = newestFiles(in: html)
            guard !links.isEmpty else { throw NSError(domain: "AddressBook", code: 1, userInfo: [NSLocalizedDescriptionKey: L("На сайті не знайдено файлів черг", "No queue files found on the site")]) }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("jackerybar-xlsx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            var all: [AddressEntry] = []
            for (i, path) in links.enumerated() {
                guard let url = URL(string: "https://hoe.com.ua" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)) else { continue }
                let file = tmp.appendingPathComponent("\(i).xlsx")
                try fetch(url).write(to: file)
                let district = districtName(path)
                all += try XLSX.rows(file).compactMap(entry(from:)).map { e in var e = e; e.district = district; return e }
            }
            return .success((links, all))
        } catch {
            return .failure(error)
        }
    }

    private static func fetch(_ url: URL) throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(ScheduleService.userAgent, forHTTPHeaderField: "User-Agent")
        var out: Result<Data, Error> = .failure(URLError(.unknown))
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, e in
            if let d, let h = r as? HTTPURLResponse, (200..<300).contains(h.statusCode) { out = .success(d) }
            else { out = .failure(e ?? URLError(.badServerResponse)) }
            sem.signal()
        }.resume()
        sem.wait()
        return try out.get()
    }

    /// Latest XLSX per district from the page ("…_09102026.xlsx" — the date is in the name).
    static func newestFiles(in html: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"/Content/Uploads/GPV6/xls/[^"'<>]+?\.xlsx"#)
        var latest: [String: (String, String)] = [:]
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let raw = String(html[Range(m.range, in: html)!])
            let path = raw.removingPercentEncoding ?? raw
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".xlsx", with: "")
            let parts = name.split(separator: "_")
            let date = parts.last.map(String.init) ?? ""
            let key = parts.dropLast().joined(separator: "_")
            // ddMMyyyy → yyyyMMdd for comparison
            let sortable = date.count == 8 ? String(date.suffix(4) + date.dropFirst(2).prefix(2) + date.prefix(2)) : date
            if (latest[key]?.1 ?? "") <= sortable { latest[key] = (path, sortable) }
        }
        return latest.values.map(\.0).sorted()
    }

    static func districtName(_ path: String) -> String {
        let n = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let r = n.range(of: "відключення_") else { return "" }
        return n[r.upperBound...].split(separator: "_").prefix { !$0.allSatisfy(\.isNumber) }.joined(separator: " ")
    }

    /// One sheet row → entry. Header and title rows are skipped.
    static func entry(from row: [String]) -> AddressEntry? {
        guard row.count >= 4 else { return nil }
        let q = row[3].trimmingCharacters(in: .whitespaces)
        guard let m = q.range(of: #"^\d+\.\d+"#, options: .regularExpression) else { return nil }
        return AddressEntry(district: "", settlement: row[0].trimmingCharacters(in: .whitespaces),
                            street: row[1].trimmingCharacters(in: .whitespaces),
                            houses: row[2].split(separator: ",").map { normalizeHouse(String($0)) }.filter { !$0.isEmpty },
                            queue: String(q[m]))
    }

    // MARK: search

    static func normalizeHouse(_ s: String) -> String {
        var h = s.uppercased().trimmingCharacters(in: .whitespaces)
        h = h.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        return h
    }

    /// Lower-cased, apostrophes unified, street-type words and punctuation dropped.
    static func normalizeName(_ s: String) -> String {
        var t = s.lowercased()
        for a in ["’", "ʼ", "`", "'", "‘"] { t = t.replacingOccurrences(of: a, with: "'") }
        for w in ["вулиця", "вул.", "провулок", "пров.", "проспект", "просп.", "площа", "пл.", "бульвар", "бульв.", "б-р",
                  "тупик", "туп.", "проїзд", "майдан", "шосе", "узвіз", "сквер", "м.", "с.", "смт", "селище", "село", "місто"] {
            t = t.replacingOccurrences(of: w, with: " ")
        }
        t = t.replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression)
        return t.split(separator: " ").joined(separator: " ")
    }

    func search(settlement: String, street: String, house: String, limit: Int = 30) -> [AddressMatch] {
        let s = Self.normalizeName(settlement), st = Self.normalizeName(street), h = Self.normalizeHouse(house)
        guard !st.isEmpty else { return [] }
        var exact: [AddressMatch] = [], loose: [AddressMatch] = []
        for e in entries {
            let es = Self.normalizeName(e.settlement)
            if !s.isEmpty && !(es == s || es.hasPrefix(s)) { continue }
            let est = Self.normalizeName(e.street)
            guard est.contains(st) else { continue }
            let m = AddressMatch(district: e.district, settlement: e.settlement, street: e.street, queue: e.queue, exactHouse: false)
            if !h.isEmpty, e.houses.contains(h) {
                var x = m; x.exactHouse = true
                if !exact.contains(x) { exact.append(x) }
            } else if h.isEmpty, !loose.contains(m) {
                loose.append(m)
            }
        }
        // A house can have several connections (several queues). Household files win over non-household ones.
        func household(_ m: AddressMatch) -> Bool { !m.district.lowercased().contains("непобут") }
        var list = exact.isEmpty ? loose : exact
        if list.contains(where: household) { list = list.filter(household) }
        return Array(list.prefix(limit))
    }
}

/// Minimal XLSX reader: unzips with the system `unzip` and reads the first sheet's A–D values.
enum XLSX {
    static func rows(_ file: URL) throws -> [[String]] {
        let strings = parseSharedStrings(try unzip(file, "xl/sharedStrings.xml"))
        return parseSheet(try unzip(file, "xl/worksheets/sheet1.xml"), strings: strings)
    }

    static func unzip(_ file: URL, _ member: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", file.path, member]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    static func parseSharedStrings(_ xml: Data) -> [String] {
        final class D: NSObject, XMLParserDelegate {
            var out: [String] = []; var cur = ""; var inT = false; var inSI = false
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                if e == "si" { inSI = true; cur = "" } else if e == "t" { inT = true }
            }
            func parser(_ p: XMLParser, foundCharacters s: String) { if inSI && inT { cur += s } }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
                if e == "t" { inT = false } else if e == "si" { out.append(cur); inSI = false }
            }
        }
        let d = D(); let p = XMLParser(data: xml); p.delegate = d; p.parse()
        return d.out
    }

    /// Rows of columns A–D (missing cells = "").
    static func parseSheet(_ xml: Data, strings: [String]) -> [[String]] {
        final class D: NSObject, XMLParserDelegate {
            let strings: [String]
            init(_ s: [String]) { strings = s }
            var rows: [[String]] = []; var row: [String] = []
            var col = -1; var type = ""; var val = ""; var inV = false
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
                switch e {
                case "row": row = ["", "", "", ""]
                case "c":
                    let ref = a["r"] ?? ""
                    col = ref.first.flatMap { $0.asciiValue }.map { Int($0) - 65 } ?? -1
                    type = a["t"] ?? "n"; val = ""
                case "v", "t": inV = true
                default: break
                }
            }
            func parser(_ p: XMLParser, foundCharacters s: String) { if inV { val += s } }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
                switch e {
                case "v", "t": inV = false
                case "c":
                    if (0..<4).contains(col) {
                        row[col] = type == "s" ? (Int(val).flatMap { $0 < strings.count ? strings[$0] : nil } ?? "") : val
                    }
                case "row": rows.append(row)
                default: break
                }
            }
        }
        let d = D(strings); let p = XMLParser(data: xml); p.delegate = d; p.parse()
        return d.rows
    }
}
