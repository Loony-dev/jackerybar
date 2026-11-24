// Human-readable formatting (localized).

import Foundation

enum Fmt {
    /// Hours → "2 год 14 хв" / "2h 14m".
    static func duration(_ h: Double) -> String {
        guard h.isFinite else { return "∞" }
        let mins = Int((h * 60).rounded())
        if mins < 60 { return L("\(max(mins, 1)) хв", "\(max(mins, 1))m") }
        if mins < 24 * 60 {
            let hh = mins / 60, mm = mins % 60
            return hh >= 10 || mm == 0 ? L("\(hh) год", "\(hh)h") : L("\(hh) год \(mm) хв", "\(hh)h \(mm)m")
        }
        let d = mins / (24 * 60), hh = (mins % (24 * 60)) / 60
        return d >= 7 ? L(">7 дн", ">7d") : (hh == 0 ? L("\(d) дн", "\(d)d") : L("\(d) дн \(hh) год", "\(d)d \(hh)h"))
    }

    /// Compact duration for the menu bar: "3г 40хв" / "3h 40m".
    static func durationShort(_ h: Double) -> String {
        guard h.isFinite else { return "∞" }
        let mins = Int((h * 60).rounded())
        if mins < 60 { return L("\(max(mins, 1))хв", "\(max(mins, 1))m") }
        if mins < 24 * 60 {
            let hh = mins / 60, mm = mins % 60
            return hh >= 10 || mm == 0 ? L("\(hh)г", "\(hh)h") : L("\(hh)г \(mm)хв", "\(hh)h \(mm)m")
        }
        let d = mins / (24 * 60)
        return d >= 7 ? L(">7д", ">7d") : L("\(d)д \((mins % (24 * 60)) / 60)г", "\(d)d \((mins % (24 * 60)) / 60)h")
    }

    /// Seconds → "2 год 14 хв" (never shorter than a minute).
    static func span(_ seconds: Double) -> String { duration(max(seconds, 60) / 3600) }

    static func watts(_ w: Double?) -> String {
        guard let w else { return "—" }
        return abs(w) >= 1000 ? String(format: L("%.2f кВт", "%.2f kW"), w / 1000) : L("\(Int(w.rounded())) Вт", "\(Int(w.rounded())) W")
    }

    /// Energy: "626 Вт·год" below 1 kWh, "1.24 кВт·год" above.
    static func energy(kWh v: Double) -> String {
        v < 1 ? L("\(Int((v * 1000).rounded())) Вт·год", "\(Int((v * 1000).rounded())) Wh")
              : String(format: L("%.2f кВт·год", "%.2f kWh"), v)
    }

    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return L("ніколи", "never") }
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return L("\(s) с тому", "\(s) s ago") }
        if s < 3600 { return L("\(s / 60) хв тому", "\(s / 60) min ago") }
        return L("\(s / 3600) год тому", "\(s / 3600) h ago")
    }

    static func clock(_ t: Double) -> String { day(t, "HH:mm") }

    static func day(_ t: Double, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = format
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
