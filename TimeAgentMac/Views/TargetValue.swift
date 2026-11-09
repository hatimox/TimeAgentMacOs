import SwiftUI

/// Logged hours against the period's target: "32.00h / 40h", green once the
/// target is met, red below it. A period with no working days (target 0)
/// shows the hours in grey with a "Day off" note instead.
struct TargetValue: View {
    @EnvironmentObject var store: AppStore
    let value: Double
    let target: Double
    var offLabel = "Day off"

    var body: some View {
        Group {
            if target <= 0 {
                Text("\(store.fmt(value)) · \(offLabel)").foregroundStyle(.secondary)
            } else {
                Text("\(store.fmt(value)) / \(Self.short(target))")
                    .foregroundStyle(value >= target - 0.005 ? Color.green : Color.red)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.6)
        .help(target <= 0 ? "No working days in this period"
                          : "\(store.fmt(value)) logged of \(Self.short(target)) expected")
    }

    /// "40h", or "37.5h" when the target isn't whole.
    static func short(_ h: Double) -> String {
        h == h.rounded() ? String(format: "%.0fh", h) : String(format: "%.1fh", h)
    }
}
