// UI language: Ukrainian (default) and English.

import Foundation

enum Lang: String, CaseIterable {
    case uk, en

    /// Current UI language; set from config.json ("language": "uk" | "en").
    static var current: Lang = .uk

    static var locale: Locale { Locale(identifier: current == .en ? "en_US" : "uk_UA") }

    var displayName: String { self == .en ? "English" : "Українська" }
}

/// Picks the string for the current language. Both variants are written side by side at the call site.
@inline(__always)
func L(_ uk: String, _ en: String) -> String { Lang.current == .en ? en : uk }
