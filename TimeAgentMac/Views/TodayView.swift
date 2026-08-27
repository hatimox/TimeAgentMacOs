import SwiftUI
import AppKit

/// Full breakdown of every time entry logged today, across all tasks —
/// editable/deletable inline, same as the per-task entry list.
struct TodayView: View {
    @EnvironmentObject var store: AppStore

    private var todayStr: String { Totals.todayString(offsetMinutes: store.settings.tzOffsetMinutes) }
    private var entries: [TimeEntry] {
        store.times.filter { $0.day == todayStr }.sorted { $0.id > $1.id }
    }
    private var total: Double { entries.reduce(0) { $0 + $1.hours } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today").font(.title2.bold())
                Spacer()
                Text(store.fmt(total)).font(.title2.monospacedDigit().bold()).foregroundStyle(.orange)
            }
            if entries.isEmpty {
                Spacer()
                Text("No time logged today").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(entries) { TodayEntryRow(entry: $0, itemName: name(for: $0.itemId)) }
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
