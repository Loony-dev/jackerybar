// Charts: a time series (line + area, two-tone around zero, hover readout) and daily bars.

import SwiftUI

struct SeriesChart: View {
    let points: [Double?]
    let metric: Metric
    let domain: ClosedRange<Double>
    var interactive = false
    var from: Double = 0
    var to: Double = 0

    @State private var hover: Int?

    /// Value range for a series: fixed for SOC/energy, includes zero for power, padded otherwise.
    static func domain(for m: Metric, points: [Double?], capacityKWh: Double) -> ClosedRange<Double> {
        let vals = points.compactMap { $0 }
        switch m {
        case .soc: return 0...100
        case .energy: return 0...max(0.1, capacityKWh)
        default: break
        }
        guard let lo = vals.min(), let hi = vals.max() else { return m.isPower ? -100...100 : 0...1 }
        if m.isPower {
            var a = min(0, lo) * 1.15, b = max(0, hi) * 1.15
            if b - a < 100 { if m.isSigned { a = min(a, -50); b = max(b, 50) } else { b = max(b, 100) } }
            return a...b
        }
        let pad = max(1, (hi - lo) * 0.25)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size) }
                if interactive, let h = hover, h < points.count {
                    overlay(index: h, size: size)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard interactive, !points.isEmpty else { return }
                switch phase {
                case .active(let p):
                    let i = Int(p.x / max(1, size.width) * CGFloat(points.count))
                    hover = min(max(i, 0), points.count - 1)
                case .ended:
                    hover = nil
                }
            }
        }
    }

    private func y(_ v: Double, _ h: CGFloat) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        return h - CGFloat((v - domain.lowerBound) / (span == 0 ? 1 : span)) * h
    }

    private func x(_ i: Int, _ w: CGFloat) -> CGFloat {
        (CGFloat(i) + 0.5) / CGFloat(max(points.count, 1)) * w
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let base = metric.isPower ? 0 : domain.lowerBound
        let baseY = y(min(max(base, domain.lowerBound), domain.upperBound), size.height)

        // Runs of consecutive buckets with data; empty buckets break the line.
        var line = Path(), area = Path()
        var run: [CGPoint] = []
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            var l = Path()
            l.move(to: first)
            if run.count == 1 { l.addLine(to: CGPoint(x: first.x + 1.5, y: first.y)) }
            for p in run.dropFirst() { l.addLine(to: p) }
            var a = l
            a.addLine(to: CGPoint(x: run.count == 1 ? first.x + 1.5 : last.x, y: baseY))
            a.addLine(to: CGPoint(x: first.x, y: baseY))
            a.closeSubpath()
            line.addPath(l); area.addPath(a)
            run.removeAll()
        }
        for (i, v) in points.enumerated() {
            if let v { run.append(CGPoint(x: x(i, size.width), y: y(v, size.height))) } else { flush() }
        }
        flush()

        if metric.isSigned {
            ctx.drawLayer { c in
                c.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: baseY)))
                c.fill(area, with: .linearGradient(Gradient(colors: [metric.tint.opacity(0.45), metric.tint.opacity(0.05)]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: baseY)))
                c.stroke(line, with: .color(metric.tint), lineWidth: 1.5)
            }
            ctx.drawLayer { c in
                c.clip(to: Path(CGRect(x: 0, y: baseY, width: size.width, height: size.height - baseY)))
                c.fill(area, with: .linearGradient(Gradient(colors: [metric.negativeTint.opacity(0.05), metric.negativeTint.opacity(0.45)]),
                                                   startPoint: CGPoint(x: 0, y: baseY), endPoint: CGPoint(x: 0, y: size.height)))
                c.stroke(line, with: .color(metric.negativeTint), lineWidth: 1.5)
            }
        } else {
            ctx.fill(area, with: .linearGradient(Gradient(colors: [metric.tint.opacity(0.4), metric.tint.opacity(0.03)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(metric.tint), lineWidth: 1.5)
        }

        if metric.isPower {
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: baseY))
            zero.addLine(to: CGPoint(x: size.width, y: baseY))
            ctx.stroke(zero, with: .color(.primary.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    @ViewBuilder
    private func overlay(index h: Int, size: CGSize) -> some View {
        let px = x(h, size.width)
        let t = from + (Double(h) + 0.5) / Double(points.count) * (to - from)
        Path { p in
            p.move(to: CGPoint(x: px, y: 0))
            p.addLine(to: CGPoint(x: px, y: size.height))
        }
        .stroke(Color.primary.opacity(0.3), lineWidth: 1)
        if let v = points[h] {
            let color = metric.isSigned && v < 0 ? metric.negativeTint : metric.tint
            Circle().fill(color).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                .position(x: px, y: y(v, size.height))
        }
        let when = to - from > 36 * 3600 ? Fmt.day(t, "dd.MM HH:mm") : Fmt.clock(t)
        let label = "\(when) · " + (points[h].map(metric.format) ?? L("немає даних", "no data"))
        Text(label)
            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
            .position(x: min(max(px, 62), size.width - 62), y: -12)
    }
}

/// Y-axis labels placed on the same scale as the chart (top, zero for power, bottom).
struct AxisLabels: View {
    let metric: Metric
    let domain: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = max(domain.upperBound - domain.lowerBound, 1e-9)
            let y = { (v: Double) -> CGFloat in h - CGFloat((v - domain.lowerBound) / span) * h }
            let zeroY = y(0)
            ZStack(alignment: .topTrailing) {
                label(domain.upperBound, at: 5)
                label(domain.lowerBound, at: h - 5)
                if metric.isPower, domain.lowerBound < 0, domain.upperBound > 0, zeroY > 16, zeroY < h - 16 {
                    label(0, at: zeroY)
                }
            }
            .frame(width: geo.size.width, height: h, alignment: .topTrailing)
        }
        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.tertiary)
    }

    private func label(_ v: Double, at y: CGFloat) -> some View {
        Text(metric.axis(v)).fixedSize()
            .frame(width: 30, alignment: .trailing)
            .position(x: 15, y: y)
    }
}


/// Daily bars with a dashed average line and a hover readout.
struct BarChart: View {
    struct Bar { let label: String; let value: Double?; let caption: String }
    let bars: [Bar]
    let tint: Color
    let format: (Double) -> String
    @State private var hover: Int?

    var body: some View {
        let vals = bars.compactMap(\.value)
        let top = max(vals.max() ?? 0, 0.001) * 1.15
        let avg = vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let slot = w / CGFloat(max(bars.count, 1))
            let barW = max(2, min(22, slot * 0.66))
            ZStack(alignment: .topLeading) {
                ForEach(bars.indices, id: \.self) { i in
                    let v = bars[i].value ?? 0
                    let bh = max(bars[i].value == nil ? 0 : 1.5, CGFloat(v / top) * h)
                    RoundedRectangle(cornerRadius: min(3, barW / 3), style: .continuous)
                        .fill(bars[i].value == nil ? Color.primary.opacity(0.08) : tint.opacity(hover == nil || hover == i ? 0.85 : 0.4))
                        .frame(width: barW, height: bars[i].value == nil ? 3 : bh)
                        .position(x: slot * (CGFloat(i) + 0.5), y: h - (bars[i].value == nil ? 1.5 : bh / 2))
                }
                if let avg, avg > 0 {
                    Path { p in
                        let y = h - CGFloat(avg / top) * h
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let i = hover, i < bars.count {
                    Text("\(bars[i].caption) · \(bars[i].value.map(format) ?? L("немає даних", "no data"))")
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .fixedSize()
                        .position(x: min(max(slot * (CGFloat(i) + 0.5), 70), w - 70), y: -12)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = min(max(Int(p.x / max(slot, 1)), 0), bars.count - 1)
                case .ended: hover = nil
                }
            }
        }
    }
}
