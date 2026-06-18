import Foundation

/// Moroccan public holidays. Port of the Electron `src/holidays.js`.
///   - FIXED civil holidays: same date every year (computed for any year).
///   - RELIGIOUS holidays: lunar, shift each year. We ship best-known estimates
///     per year; the user can confirm/adjust them in Settings (they are
///     moon-sighting dependent and may move +/-1 day).
enum Holidays {
    /// Fixed civil holidays as (month, day, name) — 1-based month.
    static let fixed: [(month: Int, day: Int, name: String)] = [
        (1, 1, "New Year's Day"),
        (1, 11, "Proclamation of Independence"),
        (1, 14, "Amazigh New Year"),
        (5, 1, "Labour Day"),
        (7, 30, "Throne Day"),
        (8, 14, "Oued Ed-Dahab Day"),
        (8, 20, "Revolution Day"),
        (8, 21, "Youth Day"),
        (11, 6, "Green March Day"),
        (11, 18, "Independence Day"),
    ]

    /// Religious holiday ESTIMATES by year (YYYY-MM-DD). Moon-sighting dependent.
    /// Each Eid spans 2+ days; single-day holidays are one entry. Ordering
    /// matters: slot keys are "year|name|index", so preserve insertion order.
    static let religious: [Int: [(name: String, dates: [String])]] = [
        2026: [
            ("Eid al-Fitr", ["2026-03-20", "2026-03-21"]),
            ("Eid al-Adha", ["2026-05-26", "2026-05-27"]),
            ("Islamic New Year", ["2026-06-16"]),
            ("Prophet's Birthday", ["2026-08-25", "2026-08-26"]),
        ],
        2027: [
            ("Eid al-Fitr", ["2027-03-09", "2027-03-10", "2027-03-11"]),
            ("Eid al-Adha", ["2027-05-16", "2027-05-17"]),
            ("Islamic New Year", ["2027-06-06"]),
            ("Prophet's Birthday", ["2027-08-15"]),
        ],
        2028: [
            ("Eid al-Fitr", ["2028-02-26", "2028-02-27"]),
            ("Eid al-Adha", ["2028-05-05", "2028-05-06"]),
            ("Islamic New Year", ["2028-05-25"]),
            ("Prophet's Birthday", ["2028-08-03"]),
        ],
    ]

    private static func pad(_ n: Int) -> String { String(format: "%02d", n) }

    /// Fixed civil holiday dates (YYYY-MM-DD) for a given year.
    static func fixedHolidays(_ year: Int) -> [String] {
        fixed.map { "\(year)-\(pad($0.month))-\(pad($0.day))" }
    }

    /// Fixed civil holidays with names for a given year.
    static func fixedHolidaysNamed(_ year: Int) -> [(date: String, name: String)] {
        fixed.map { (date: "\(year)-\(pad($0.month))-\(pad($0.day))", name: $0.name) }
    }

    /// Religious holiday estimates for a year. Empty if unknown.
    static func religiousHolidays(_ year: Int) -> [(name: String, dates: [String])] {
        religious[year] ?? []
    }

    /// All years we have religious estimates for, sorted.
    static func religiousYears() -> [Int] {
        religious.keys.sorted()
    }
}
