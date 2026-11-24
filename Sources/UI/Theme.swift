// Shared look: colours, small reusable views, snapshot stand-ins.

import SwiftUI

enum Palette {
    static let green = Color(red: 0.30, green: 0.82, blue: 0.50)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.25)
    static let red = Color(red: 1.00, green: 0.38, blue: 0.33)
    static let discharge = Color(red: 1.00, green: 0.58, blue: 0.28)

    static func forSoc(_ soc: Double) -> Color { soc >= 50 ? green : soc >= 20 ? amber : red }
}

extension Metric {
    /// Main colour; for signed metrics this is the colour above zero.
    var tint: Color {
        switch self {
        case .battery, .soc: Palette.green
        case .grid, .wifi: .blue
        case .ac: .purple
        case .pv: Palette.amber
        case .energy: .teal
        case .temp: .pink
        }
    }

    /// Colour below zero for signed metrics.
    var negativeTint: Color { self == .grid ? Palette.green : Palette.discharge }
}

/// True while rendering README screenshots: AppKit-backed controls (text fields, switches,
/// segmented pickers, scroll views) can't be drawn off-screen, so static look-alikes are used instead.
enum Snapshot { static var active = false }

/// Page title with a back button.
struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var tint: Color = .secondary
    let back: () -> Void
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help(L("Назад", "Back"))
            if let icon { Image(systemName: icon).foregroundStyle(tint) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
            Spacer()
            if let trailing { trailing }
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct StatCell: View {
    let title: String
    let value: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let caption {
                Text(caption.isEmpty ? " " : caption).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct Grid3<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) { content }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 26, height: 22)
                .background(Color.primary.opacity(hover ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// Capsule segmented control drawn in SwiftUI (renders in screenshots, unlike NSSegmentedControl).
struct Chips<T: Hashable>: View {
    let items: [(String, T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let (label, value) = items[i]
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(selection == value ? Color.primary.opacity(0.16) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == value ? .primary : .secondary)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// A switch that renders in screenshots too.
struct SwitchView: View {
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        if Snapshot.active {
            FakeSwitch(on: isOn)
        } else {
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}

struct FakeSwitch: View {
    let on: Bool
    var body: some View {
        Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.2))
            .frame(width: 26, height: 15)
            .overlay(Circle().fill(.white).frame(width: 13, height: 13).shadow(radius: 0.5)
                .offset(x: on ? 5.5 : -5.5))
    }
}

/// Inline confirmation box (system alerts don't play well with the floating popup).
struct ConfirmBox: View {
    let text: String
    let confirm: String
    var destructive = true
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(destructive ? Palette.red : Palette.amber)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Скасувати", "Cancel"), action: onCancel)
                Button(action: onConfirm) {
                    Text(confirm).foregroundStyle(destructive ? Palette.red : .primary)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background((destructive ? Palette.red : Palette.amber).opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// "−  80 %  +" stepper drawn in SwiftUI.
struct StepperRow: View {
    let title: String
    var caption: String? = nil
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    let set: (Int) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let caption { Text(caption).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer()
            HStack(spacing: 0) {
                stepButton("minus", enabled: value > range.lowerBound) { set(snap(value, down: true)) }
                Text("\(value)\(unit)")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .frame(minWidth: 58)
                stepButton("plus", enabled: value < range.upperBound) { set(snap(value, down: false)) }
            }
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }

    private func snap(_ v: Int, down: Bool) -> Int {
        let next = down ? ((v - 1) / step) * step : (v / step + 1) * step
        return min(range.upperBound, max(range.lowerBound, next))
    }

    private func stepButton(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
    }
}
