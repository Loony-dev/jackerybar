// Downloads planned-outage schedules and keeps a disk cache, so the last good copy survives restarts
// and network trouble (which is exactly when the power is off).

import Foundation

final class ScheduleService {
    static let kolyBase = URL(string: "https://vkardin.github.io/koly/v1/")!
    static let frankovBase = URL(string: "https://raw.githubusercontent.com/frankov-dev/khm_outage_parser/master/docs/")!
    static let userAgent = "JackeryBar (+https://github.com/Loony-dev/jackerybar)"
    static let refreshEvery: TimeInterval = 10 * 60

    private(set) var index: [RegionInfo] = []
    private(set) var schedules: [String: RegionSchedule] = [:]
    private(set) var lastError: [String: String] = [:]
    private(set) var lastAttempt: [String: Date] = [:]
    private var regions: Set<String> = []
    private var timer: Timer?
    private let session: URLSession

    var onUpdate: () -> Void = {}
    /// A region's schedule was replaced: (region id, previous copy, new copy).
    var onChange: (String, RegionSchedule?, RegionSchedule) -> Void = { _, _, _ in }

    init(session: URLSession? = nil) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = session ?? URLSession(configuration: cfg)
        loadCache()
    }

    func schedule(_ region: String) -> RegionSchedule? { schedules[region] }
    func region(_ id: String) -> RegionInfo? { index.first { $0.id == id } }

    /// Which regions to keep fresh. Starts the 10-minute timer.
    func track(_ ids: Set<String>) {
        regions = ids
        timer?.invalidate()
        guard !ids.isEmpty else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        for id in regions { fetchRegion(id) }
        if index.isEmpty || (Date().timeIntervalSince(lastAttempt["#index"] ?? .distantPast) > 86400) { fetchIndex() }
    }

    func fetchIndex(done: (() -> Void)? = nil) {
        lastAttempt["#index"] = Date()
        get(Self.kolyBase.appendingPathComponent("index.json")) { [weak self] data in
            guard let self else { return }
            if let data, let idx = try? JSONDecoder().decode(RegionIndex.self, from: data), !idx.regions.isEmpty {
                self.index = idx.regions
                try? data.write(to: Paths.dir.appendingPathComponent("schedule-index.json"), options: .atomic)
                self.onUpdate()
            }
            done?()
        }
    }

    /// Other sources for the same region (only Khmelnytskyi has them), kept to cross-check the primary one.
    private(set) var secondaries: [String: [RegionSchedule]] = [:]

    private func fetchRegion(_ id: String) {
        lastAttempt[id] = Date()
        var koly: RegionSchedule?, frankov: RegionSchedule?, hoe: RegionSchedule?
        let group = DispatchGroup()
        group.enter()
        get(Self.kolyBase.appendingPathComponent("regions/\(id).json")) { data in
            if let data, var s = try? JSONDecoder().decode(RegionSchedule.self, from: data), s.status == "ok" || s.status == "no_schedules" {
                s.feed = "koly"
                koly = s
            }
            group.leave()
        }
        if id == "khmelnytskyi" {
            group.enter()
            fetchFrankov { frankov = $0; group.leave() }
            group.enter()
            HoeParser.fetch(session: session) { hoe = $0; group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // The operator's own posts win when they parse completely for today; then Koly, then the other parser.
            let today = RegionSchedule.dayString()
            let hoeOK = hoe.map { h in h.days.contains { $0.date == today && $0.groups.count >= 12 } } ?? false
            let ranked = ([hoeOK ? hoe : nil, koly, frankov] + [hoeOK ? nil : hoe]).compactMap { $0 }
            guard let primary = ranked.first else {
                self.lastError[id] = L("Графік зараз недоступний", "Schedule unavailable right now")
                self.onUpdate()
                return
            }
            self.secondaries[id] = Array(ranked.dropFirst())
            self.accept(primary, id: id)
        }
    }

    /// Khmelnytskyi second source (frankov-dev/khm_outage_parser).
    private func fetchFrankov(_ done: @escaping (RegionSchedule?) -> Void) {
        let names = ["today.json", "tomorrow.json"]
        var files: [Data?] = Array(repeating: nil, count: names.count)
        let group = DispatchGroup()
        for (i, n) in names.enumerated() {
            group.enter()
            get(Self.frankovBase.appendingPathComponent(n)) { data in files[i] = data; group.leave() }
        }
        group.notify(queue: .main) { done(RegionSchedule.fromFrankov(files.compactMap { $0 })) }
    }

    /// Where other sources disagree with the primary one about a queue (today and later).
    func disagreements(_ region: String, group: String, today: String = RegionSchedule.dayString()) -> [SourceDisagreement] {
        guard let a = schedules[region] else { return [] }
        return (secondaries[region] ?? []).flatMap { SourceDisagreement.compare(a, $0, group: group, today: today) }
    }

    /// Where a person can check the operator's own publication.
    static func operatorPage(_ region: String, fallback: String?) -> URL? {
        region == "khmelnytskyi" ? URL(string: "https://hoe.com.ua/post/novini-kompaniji") : fallback.flatMap(URL.init(string:))
    }

    /// Screenshots / tests.
    func injectSecondary(_ s: RegionSchedule) { secondaries[s.id, default: []].append(s) }

    private func accept(_ s: RegionSchedule, id: String) {
        let old = schedules[id]
        schedules[id] = s
        if old?.days != s.days { onChange(id, old, s) }
        lastError[id] = nil
        if let d = try? JSONEncoder().encode(s) {
            try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
            try? d.write(to: Paths.dir.appendingPathComponent("schedule-\(id).json"), options: .atomic)
        }
        onUpdate()
    }

    private func get(_ url: URL, _ done: @escaping (Data?) -> Void) {
        session.dataTask(with: url) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async { done(ok ? data : nil) }
        }.resume()
    }

    private func loadCache() {
        if let d = try? Data(contentsOf: Paths.dir.appendingPathComponent("schedule-index.json")),
           let idx = try? JSONDecoder().decode(RegionIndex.self, from: d) { index = idx.regions }
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.dir, includingPropertiesForKeys: nil)) ?? []
        for u in files where u.lastPathComponent.hasPrefix("schedule-") && u.lastPathComponent != "schedule-index.json" {
            if let d = try? Data(contentsOf: u), let s = try? JSONDecoder().decode(RegionSchedule.self, from: d) { schedules[s.id] = s }
        }
    }

    /// Screenshots / tests.
    func inject(_ s: RegionSchedule, index idx: [RegionInfo] = []) {
        schedules[s.id] = s
        if !idx.isEmpty { index = idx }
    }
}
