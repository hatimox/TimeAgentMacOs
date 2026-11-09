import SwiftUI

/// The menu-bar popover: signed-in user, In-meeting indicator, Split/Stop
/// controls (only during a call), today/week/month totals, and actions.
struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var watcher: MeetingWatcher
    @State private var dayOffset = 0
    @State private var weekOffset = 0
    @State private var monthOffset = 0
    @State private var elapsed = ""
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if watcher.inMeeting { meetingControls }
            totals
            actions
            if !store.status.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle").font(.caption2)
                    Text(store.status).font(.caption2).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Text(AppInfo.displayVersion).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 312)
        .background(.ultraThinMaterial)
        .onReceive(tick) { _ in updateElapsed() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(name: store.settings.myUserName.isEmpty ? "TimeAgent" : store.settings.myUserName,
                       email: store.settings.myUserEmail, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(store.settings.myUserName.isEmpty ? "TimeAgent" : store.settings.myUserName)
                        .font(.headline)
                    if watcher.inMeeting {
                        Circle().fill(.red).frame(width: 7, height: 7)
                            .shadow(color: .red.opacity(0.6), radius: 2)
                    }
                }
                if watcher.inMeeting {
                    Text("In meeting · \(elapsed)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.red)
                } else if !store.settings.myUserName.isEmpty {
                    Text("Ready").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: meeting controls

    private var meetingControls: some View {
        HStack(spacing: 8) {
            Button { Task { await watcher.splitNow() } } label: {
                Label("Split", systemImage: "scissors").frame(maxWidth: .infinity)
            }
            Button { Task { await watcher.stopTracking() } } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }.tint(.red)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.red.opacity(0.18)))
    }

    // MARK: totals

    private var totals: some View {
        let t = store.totals(dayOffset: dayOffset, weekOffset: weekOffset, monthOffset: monthOffset)
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                tile("Day", t.day, t.dayTarget, t.dayLabel, "sun.max", .orange, offset: $dayOffset) {
                    store.viewDayOffset = dayOffset
                    AppDelegate.shared?.openToday()
                }
                tile("Week", t.week, t.weekTarget, t.weekLabel, "calendar", .blue, offset: $weekOffset)
            }
            HStack {
                stepButton("chevron.left") { monthOffset -= 1 }
                Spacer()
                VStack(spacing: 1) {
                    TargetValue(value: t.month, target: t.monthTarget, offLabel: "No working days")
                        .font(.title2.monospacedDigit().bold())
                    Text(t.monthLabel).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                stepButton("chevron.right") { if monthOffset < 0 { monthOffset += 1 } }
                    .disabled(monthOffset >= 0)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// A total card with its own ‹ › period stepper. `open`, if given, makes the
    /// value clickable (the Day card opens the day's entry list).
    private func tile(_ label: String, _ v: Double, _ target: Double, _ period: String, _ icon: String, _ color: Color,
                      offset: Binding<Int>, open: (() -> Void)? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                stepButton("chevron.left") { offset.wrappedValue -= 1 }
                Spacer(minLength: 0)
                Image(systemName: icon).font(.caption2).foregroundStyle(color)
                Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
                stepButton("chevron.right") { if offset.wrappedValue < 0 { offset.wrappedValue += 1 } }
                    .disabled(offset.wrappedValue >= 0)
            }
            Group {
                if let open {
                    Button(action: open) { TargetValue(value: v, target: target) }.buttonStyle(.plain)
                        .help("Show this day's entries")
                } else {
                    TargetValue(value: v, target: target, offLabel: "Days off")
                }
            }
            .font(.title3.monospacedDigit().bold())
            Text(period).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8).padding(.horizontal, 4)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.15)))
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.caption.weight(.semibold)).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
    }

    // MARK: actions

    private var actions: some View {
        VStack(spacing: 8) {
            Button { AppDelegate.shared?.openTasks() } label: {
                Label("Open tasks…", systemImage: "list.bullet.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 8) {
                Button { AppDelegate.shared?.openSettings() } label: {
                    Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                Button { Task { await store.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").frame(maxWidth: .infinity)
                }.tint(.red)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.regular)
    }

    private func updateElapsed() {
        guard let s = watcher.sessionStart else { elapsed = ""; return }
        let secs = Int(Date().timeIntervalSince(s))
        elapsed = secs >= 3600
            ? String(format: "%d:%02d:%02d", secs/3600, (secs%3600)/60, secs%60)
            : String(format: "%d:%02d", secs/60, secs%60)
    }
}
