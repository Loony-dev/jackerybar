// Inverter loss model learned from real discharge periods.

import Foundation

/// Learns how much the battery has to give for a given AC output, from real discharge periods:
/// batteryDraw = slope × outputW + intercept, where `intercept` is the station's own consumption.
/// Used to estimate runtime while the station is charging (when the battery isn't feeding the load).
final class LossModel {
    private(set) var pairs: [[Double]] = []   // [outputW, batteryW]
    private var lastAdd: Date?
    private(set) var slope = 1 / 0.9          // default ~90 % until learned
    private(set) var intercept = 0.0
    private(set) var isLinear = false

    var isLearned: Bool { pairs.count >= 6 }

    func add(output: Double, battery: Double, at t: Date = Date()) {
        guard output >= 10, battery >= 30 else { return }
        let r = battery / output
        guard r >= 0.95, r <= 1.8 else { return }          // mismatched/transitional readings
        if let l = lastAdd, t.timeIntervalSince(l) < 20 { return }
        lastAdd = t
        pairs.append([output, battery])
        if pairs.count > 400 { pairs.removeFirst(pairs.count - 400) }
        fit()
    }

    private func fit() {
        guard pairs.count >= 6 else { return }
        let n = Double(pairs.count)
        let xs = pairs.map { $0[0] }, ys = pairs.map { $0[1] }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) } / n
        // Need a real spread of loads to separate fixed and proportional losses.
        if sxx > 40 * 40 {
            let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / n
            let a = sxy / sxx, b = my - a * mx
            if (1.0...1.4).contains(a), (0...80).contains(b) {
                slope = a; intercept = b; isLinear = true
                return
            }
        }
        slope = min(1.6, max(1.0, my / mx)); intercept = 0; isLinear = false
    }

    /// Battery power needed to deliver `output` watts.
    func batteryDraw(output: Double) -> Double { output < 1 ? intercept : slope * output + intercept }

    /// Efficiency (output / battery) at the given output.
    func efficiency(output: Double) -> Double? {
        let d = batteryDraw(output: output)
        return d > 0 && output >= 1 ? output / d : nil
    }

    func load(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([[Double]].self, from: data) else { return }
        pairs = rows.filter { $0.count == 2 }.suffix(400).map { $0 }
        fit()
    }

    func reset() {
        pairs.removeAll(); lastAdd = nil
        slope = 1 / 0.9; intercept = 0; isLinear = false
    }

    func save(to url: URL) {
        guard !pairs.isEmpty, let data = try? JSONEncoder().encode(pairs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
