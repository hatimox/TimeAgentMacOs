import Foundation

/// Recurring auto-logging — port of `logRecurringIfDue` / `allDaysOff` from the
/// Electron `src/main.js`. Logs every configured recurring entry once per
/// working day (skipping weekly days off + holidays), deduped via a
/// `recurring_logged.json` ledger keyed by "date|taskId" so it never
/// double-logs across restarts.
enum RecurringLogger {
    /// Combined set of days off for a year: user-added + confirmed religious +
    /// (when region is Morocco) the fixed civil holidays.
    static func allDaysOff(year: Int, settings: Settings) -> Set<String> {
        var out = Set(settings.daysOff)
        for slot in settings.religiousSlots where slot.on && !slot.date.isEmpty {
            out.insert(slot.date)
        }
        if settings.region == "morocco" {
            for d in Holidays.fixedHolidays(year) { out.insert(d) }
        }
        return out
    }

    private static var ledgerFile: URL { Settings.dir.appendingPathComponent("recurring_logged.json") }

    static func loadLedger() -> Set<String> {
        guard let data = try? Data(contentsOf: ledgerFile),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return Set(arr)
    }

    static func saveLedger(_ set: Set<String>) {
        if let data = try? JSONSerialization.data(withJSONObject: Array(set)) {
            try? data.write(to: ledgerFile)
        }
    }

    /// "Today" (YYYY-MM-DD) and weekday (0=Sun … 6=Sat) in the work timezone,
    /// using the same noon-free UTC-shift approach as the Electron client.
    static func localDay(now: Date, tzOffsetMinutes: Int) -> (today: String, weekday: Int, year: Int) {
        let local = now.addingTimeInterval(Double(tzOffsetMinutes) * 60)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: local)
        let today = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        return (today, (c.weekday! - 1), c.year!)   // Calendar weekday is 1=Sun
    }
}
