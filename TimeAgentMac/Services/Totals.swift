import Foundation

/// Today / week / month totals from the cached time entries, bucketed by the
/// offset-aware day strings (same approach as the Electron app).
enum Totals {
    static func compute(_ times: [TimeEntry], offsetMinutes: Int, monthOffset: Int = 0)
        -> (today: Double, week: Double, month: Double, monthLabel: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60) ?? .current
        let now = Date()
        let todayStr = dayString(now, cal)
        // Monday-start week.
        let weekday = cal.component(.weekday, from: now)   // 1=Sun…7=Sat
        let backToMon = (weekday + 5) % 7
        let weekStart = cal.date(byAdding: .day, value: -backToMon, to: now)!
        let weekStartStr = dayString(weekStart, cal)

        let mbase = cal.date(byAdding: .month, value: monthOffset, to: now)!
        let mc = cal.dateComponents([.year, .month], from: mbase)
        let prefix = String(format: "%04d-%02d", mc.year ?? 0, mc.month ?? 0)

        var today = 0.0, week = 0.0, month = 0.0
        for t in times {
            if t.day == todayStr { today += t.hours }
            if t.day >= weekStartStr { week += t.hours }
            if t.day.hasPrefix(prefix) { month += t.hours }
        }
        let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; f.timeZone = cal.timeZone
        return (today, week, month, f.string(from: mbase))
    }

    private static func dayString(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
