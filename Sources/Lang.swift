// UI language: Ukrainian (default) and English.

import Foundation

enum Lang: String, CaseIterable {
    case uk, en

    /// Current UI language; set from config.json ("language": "uk" | "en").
    static var current: Lang = .uk

    static var locale: Locale { Locale(identifier: current == .en ? "en_US" : "uk_UA") }

    var displayName: String { self == .en ? "English" : "Українська" }
}

/// True while rendering README screenshots: AppKit-backed controls (text fields, switches,
/// segmented pickers) can't be drawn off-screen, so static look-alikes are used instead.
enum Snapshot { static var active = false }

/// Static stand-in for a switch, used in snapshot mode.
import SwiftUI
struct FakeSwitch: View {
    let on: Bool
    var body: some View {
        Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.2))
            .frame(width: 26, height: 15)
            .overlay(Circle().fill(.white).frame(width: 13, height: 13).shadow(radius: 0.5)
                .offset(x: on ? 5.5 : -5.5))
    }
}

/// Static stand-in for a segmented picker, used in snapshot mode.
struct FakeSegmented: View {
    let options: [String]
    let selected: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Text(options[i]).font(.system(size: 12, weight: i == selected ? .medium : .regular))
                    .frame(maxWidth: .infinity).padding(.vertical, 3)
                    .background(i == selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(i == selected ? .white : .primary)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Picks the string for the current language. Both variants are written side by side at the call site.
@inline(__always)
func L(_ uk: String, _ en: String) -> String { Lang.current == .en ? en : uk }
