import SwiftUI
import AppKit

/// Full breakdown of every time entry logged on one day (today by default),
/// across all tasks — editable/deletable inline, with ‹ › to browse days.
struct TodayView: View {
    @EnvironmentObject var store: AppStore

    private var offset: Int { store.viewDayOffset }
    private var dayStr: String { Totals.dayString(offset: offset, offsetMinutes: store.settings.tzOffsetMinutes) }
    private var entries: [TimeEntry] {
        store.times.filter { $0.day == dayStr }.sorted { $0.id > $1.id }
    }
    private var total: Double { entries.reduce(0) { $0 + $1.hours } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button { store.viewDayOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .help("Previous day")
                Button { if offset < 0 { store.viewDayOffset += 1 } } label: { Image(systemName: "chevron.right") }
                    .disabled(offset >= 0).help("Next day")
                Text(Totals.longDayLabel(offset: offset, offsetMinutes: store.settings.tzOffsetMinutes))
                    .font(.title2.bold()).lineLimit(1)
                if offset != 0 {
                    Button("Today") { store.viewDayOffset = 0 }.controlSize(.small)
                }
                Spacer()
                TargetValue(value: total, target: store.totals(dayOffset: offset).dayTarget)
                    .font(.title2.monospacedDigit().bold()).fixedSize()
            }
            if entries.isEmpty {
                Spacer()
                Text(offset == 0 ? "No time logged today" : "No time logged on this day").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(entries) { TodayEntryRow(entry: $0, itemName: name(for: $0.itemId)).id($0) }
                    .listStyle(.inset)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func name(for itemId: Int) -> String {
        store.items.first { $0.id == itemId }.map { "#\($0.id) — \($0.name)" } ?? "#\(itemId)"
    }
}

private struct TodayEntryRow: View {
    @EnvironmentObject var store: AppStore
    let entry: TimeEntry
    let itemName: String
    @State private var hrs = ""
    @State private var note = ""

    var body: some View {
        HStack(spacing: 8) {
            Button { store.openInTP(entry.itemId) } label: {
                Text(itemName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .help("Open in TargetProcess")
            TextField("hrs", text: $hrs).frame(width: 50).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
            TextField("note", text: $note).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
            Button { save() } label: { Image(systemName: "checkmark") }
                .buttonStyle(.borderedProminent).tint(.green)
            Button { confirmDelete() } label: { Image(systemName: "trash") }.tint(.red)
        }
        .controlSize(.small)
        .onAppear { hrs = String(entry.hours); note = entry.description }
    }

    private func save() {
        guard let h = Double(hrs.replacingOccurrences(of: ",", with: ".")), h > 0 else { return }
        Task { await store.updateTime(entry, hours: h, description: note, dayISO: entry.day) }
    }

    private func confirmDelete() {
        let a = NSAlert(); a.messageText = "Delete this time entry?"
        a.informativeText = "\(itemName) · \(store.fmt(entry.hours))"
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { Task { await store.deleteTime(entry) } }
    }
}
