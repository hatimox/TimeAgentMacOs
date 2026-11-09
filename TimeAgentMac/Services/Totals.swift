import Foundation

/// Day / week / month totals from the cached time entries, bucketed by the
/// offset-aware day strings (same approach as the Electron app). Each period
/// can be shifted into the past independently (0 = current, -1 = previous…).
enum Totals {
    struct Result {
        var day: Double, week: Double, month: Double
        var dayLabel: String, weekLabel: String, monthLabel: String
        /// Hours expected for each full period (working days × hours per day).
        var dayTarget = 0.0, weekTarget = 0.0, monthTarget = 0.0
    }

    /// Which days count toward the target: (day "YYYY-MM-DD", weekday 0=Sun…6=Sat) → working?
    typealias WorkingDay = (String, Int) -> Bool

    static func compute(_ times: [TimeEntry], offsetMinutes: Int,
                        dayOffset: Int = 0, weekOffset: Int = 0, monthOffset: Int = 0,
                        hoursPerDay: Double = 0, isWorkingDay: WorkingDay = { _, _ in true }) -> Result {
        let cal = calendar(offsetMinutes)
        let now = Date()

        let dayDate = cal.date(byAdding: .day, value: dayOffset, to: now)!
        let dayStr = dayString(dayDate, cal)

        // Monday-start week, shifted by whole weeks.
        let weekday = cal.component(.weekday, from: now)   // 1=Sun…7=Sat
        let thisMonday = cal.date(byAdding: .day, value: -((weekday + 5) % 7), to: now)!
        let weekStart = cal.date(byAdding: .day, value: 7 * weekOffset, to: thisMonday)!
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart)!
        let weekStartStr = dayString(weekStart, cal), weekEndStr = dayString(weekEnd, cal)

        let mbase = cal.date(byAdding: .month, value: monthOffset, to: now)!
        let mc = cal.dateComponents([.year, .month], from: mbase)
        let prefix = String(format: "%04d-%02d", mc.year ?? 0, mc.month ?? 0)
        let monthStart = cal.date(from: mc)!
        let monthDays = cal.range(of: .day, in: .month, for: monthStart)!.count

        // Targets cover the whole period, past and future days alike.
        func target(from start: Date, days: Int) -> Double {
            (0..<days).reduce(0.0) { acc, i in
                let d = cal.date(byAdding: .day, value: i, to: start)!
                let wd = cal.component(.weekday, from: d) - 1        // 0=Sun…6=Sat
                return isWorkingDay(dayString(d, cal), wd) ? acc + hoursPerDay : acc
            }
        }

        var day = 0.0, week = 0.0, month = 0.0
        for t in times {
            if t.day == dayStr { day += t.hours }
            if t.day >= weekStartStr && t.day <= weekEndStr { week += t.hours }
            if t.day.hasPrefix(prefix) { month += t.hours }
        }

        let mf = DateFormatter(); mf.dateFormat = "LLLL yyyy"; mf.timeZone = cal.timeZone
        let df = DateFormatter(); df.dateFormat = "EEE d MMM"; df.timeZone = cal.timeZone
        let dayLabel = dayOffset == 0 ? "Today" : dayOffset == -1 ? "Yesterday" : df.string(from: dayDate)
        let wf = DateFormatter(); wf.dateFormat = "d MMM"; wf.timeZone = cal.timeZone
        let weekLabel = weekOffset == 0 ? "This week" : weekOffset == -1 ? "Last week"
            : "\(wf.string(from: weekStart)) – \(wf.string(from: weekEnd))"
        return Result(day: day, week: week, month: month,
                      dayLabel: dayLabel, weekLabel: weekLabel, monthLabel: mf.string(from: mbase),
                      dayTarget: target(from: dayDate, days: 1),
                      weekTarget: target(from: weekStart, days: 7),
                      monthTarget: target(from: monthStart, days: monthDays))
    }

    static func todayString(offsetMinutes: Int) -> String { dayString(offset: 0, offsetMinutes: offsetMinutes) }

    /// "YYYY-MM-DD" for today shifted by `offset` days, in the configured zone.
    static func dayString(offset: Int, offsetMinutes: Int) -> String {
        let cal = calendar(offsetMinutes)
        return dayString(cal.date(byAdding: .day, value: offset, to: Date())!, cal)
    }

    /// Long label for a day offset, e.g. "Today", "Yesterday", "Friday 6 November 2026".
    static func longDayLabel(offset: Int, offsetMinutes: Int) -> String {
        if offset == 0 { return "Today" }
        if offset == -1 { return "Yesterday" }
        let cal = calendar(offsetMinutes)
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy"; f.timeZone = cal.timeZone
        return f.string(from: cal.date(byAdding: .day, value: offset, to: Date())!)
    }

    private static func calendar(_ offsetMinutes: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60) ?? .current
        return cal
    }

    private static func dayString(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
