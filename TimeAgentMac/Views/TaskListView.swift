import SwiftUI

/// The main window: searchable/filterable task & bug list with per-item state
/// change, collapsible parent-US grouping, hours total, and direct time logging.
enum TaskSort: String, CaseIterable, Identifiable {
    case name = "Name A–Z"
    case idDesc = "Newest (#id ↓)"
    case idAsc = "Oldest (#id ↑)"
    case type = "Type (Bug/Task)"
    case state = "State"
    case sprint = "Sprint"
    case hours = "My hours ↓"
    var id: String { rawValue }
}

private let kSprintCurrent = "__current"
private let kSprintNone = "__none"

struct TaskListView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var activeOnly = true
    @State private var stateFilter = "All"
    @State private var sprintFilter = kSprintCurrent
    @State private var sortBy: TaskSort = .name
    @State private var monthOffset = 0
    /// Expanded US group ids, persisted as a comma list; groups start collapsed.
    @AppStorage("expandedUS") private var expandedRaw = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 820, minHeight: 560)
        .task { if store.items.isEmpty { await store.refresh() } }
    }

    // MARK: derived filter option lists

    /// Distinct workflow-state names present in the loaded items.
    private var stateOptions: [String] {
        Array(Set(store.items.map(\.stateName))).filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Distinct sprint names present, newest first (sprints are often numbered).
    private var sprintOptions: [String] {
        Array(Set(store.items.map(\.sprint))).filter { !$0.isEmpty }
            .sorted { ($0.numericPrefix ?? -1, $0) > ($1.numericPrefix ?? -1, $1) }
    }

    private var hasUnscheduled: Bool { store.items.contains { $0.sprint.isEmpty } }

    // MARK: toolbar

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                searchField
                Toggle(isOn: $activeOnly) { Label("Active", systemImage: "circle.dashed") }
                    .toggleStyle(.button).controlSize(.regular)
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.loading)
                Button { AppDelegate.shared?.openSettings() } label: { Image(systemName: "gearshape") }
            }
            HStack(spacing: 10) {
                filterPicker("Sprint", systemImage: "flag", selection: $sprintFilter) {
                    Text("Current sprint").tag(kSprintCurrent)
                    Text("All sprints").tag("All")
                    Divider()
                    ForEach(sprintOptions, id: \.self) { Text($0).tag($0) }
                    if hasUnscheduled { Text("(no sprint)").tag(kSprintNone) }
                }
                .onChange(of: sprintFilter) { v in
                    // "Current sprint" is a server-scoped fetch; everything else
                    // filters the full set client-side, so load all when leaving it.
                    let wantAll = v != kSprintCurrent
                    if store.scopeAll != wantAll { store.scopeAll = wantAll; Task { await store.refresh() } }
                }

                filterPicker("Status", systemImage: "circle.fill", selection: $stateFilter) {
                    Text("All statuses").tag("All")
                    Divider()
                    ForEach(stateOptions, id: \.self) { Text($0).tag($0) }
                }

                filterPicker("Sort", systemImage: "arrow.up.arrow.down", selection: $sortBy) {
                    ForEach(TaskSort.allCases) { Text($0.rawValue).tag($0) }
                }
                Spacer()
                Button { expanded = Set(groups.map(\.id)) } label: {
                    Label("Expand all", systemImage: "chevron.down.2")
                }
                Button { expanded = [] } label: {
                    Label("Collapse all", systemImage: "chevron.up.2")
                }
            }
        }
        .padding(10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.callout)
            TextField("Search tasks & bugs (name or #id)…", text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 340)
    }

    private func filterPicker<T: Hashable, C: View>(_ label: String, systemImage: String,
                                                    selection: Binding<T>,
                                                    @ViewBuilder _ content: () -> C) -> some View {
        Picker(selection: selection) { content() } label: {
            Label(label, systemImage: systemImage)
        }
        .pickerStyle(.menu).fixedSize()
    }

    @ViewBuilder private var content: some View {
        if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: store.loading ? "hourglass" : "tray")
                    .font(.largeTitle).foregroundStyle(.tertiary)
                Text(store.loading ? "Loading…" : "No matching tasks")
                    .foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(groups) { g in
                        groupHeader(g)
                        if isExpanded(g) {
                            ForEach(g.items) { item in ItemRow(item: item).padding(.leading, 14) }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    // MARK: US grouping

    private struct USGroup: Identifiable {
        let id: Int                 // US id; 0 = no user story
        let name: String
        let items: [WorkItem]
        let hours: Double
    }

    /// Filtered items bucketed by parent US. Items keep the chosen sort order;
    /// groups are ordered by US name (or total hours for the hours sort), with
    /// the "No User Story" bucket last.
    private var groups: [USGroup] {
        let list = filtered
        var order: [Int] = []
        var buckets: [Int: [WorkItem]] = [:]
        for it in list {
            if buckets[it.usId] == nil { order.append(it.usId) }
            buckets[it.usId, default: []].append(it)
        }
        let gs = order.map { id -> USGroup in
            let items = buckets[id]!
            return USGroup(id: id, name: id == 0 ? "No User Story" : items[0].usName,
                           items: items, hours: items.reduce(0) { $0 + store.hours(for: $1.id) })
        }
        return gs.sorted { a, b in
            if (a.id == 0) != (b.id == 0) { return b.id == 0 }
            if sortBy == .hours && a.hours != b.hours { return a.hours > b.hours }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var expanded: Set<Int> {
        get { Set(expandedRaw.split(separator: ",").compactMap { Int($0) }) }
        nonmutating set { expandedRaw = newValue.sorted().map(String.init).joined(separator: ",") }
    }

    /// An active search expands everything so matches aren't hidden.
    private func isExpanded(_ g: USGroup) -> Bool { !search.isEmpty || expanded.contains(g.id) }

    private func groupHeader(_ g: USGroup) -> some View {
        let open = isExpanded(g)
        return HStack(spacing: 8) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.caption.bold()).foregroundStyle(.secondary).frame(width: 12)
            if g.id != 0 {
                Button("US #\(g.id)") { store.openInTP(g.id) }
                    .buttonStyle(.link).font(.caption.monospacedDigit())
            }
            Text(g.name).fontWeight(.semibold).lineLimit(1)
            Text("\(g.items.count)").font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
            if g.hours > 0 {
                Label(store.fmt(g.hours), systemImage: "clock")
                    .font(.caption.monospacedDigit()).foregroundStyle(.green)
            }
            if g.id != 0 {
                Button {
                    AppDelegate.shared?.openAgent(.story(id: g.id, name: g.name, projectName: g.items[0].projectName))
                } label: {
                    Label(store.agentActive(g.id) ? "Agent running" : "Run agent", systemImage: "sparkles").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small).tint(.purple)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            var e = expanded
            if e.contains(g.id) { e.remove(g.id) } else { e.insert(g.id) }
            expanded = e
        }
    }

    // MARK: footer — status + tracked-time totals

    private var statusBar: some View {
        let t = Totals.compute(store.times, offsetMinutes: store.settings.tzOffsetMinutes, monthOffset: monthOffset)
        return HStack(spacing: 12) {
            if store.loading { ProgressView().controlSize(.small) }
            Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("\(filtered.count) shown").font(.caption).foregroundStyle(.tertiary)
            Divider().frame(height: 22)
            stat("Today", t.today)
            stat("Week", t.week)
            HStack(spacing: 4) {
                Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                stat(t.monthLabel, t.month)
                Button { if monthOffset < 0 { monthOffset += 1 } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).disabled(monthOffset >= 0)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func stat(_ label: String, _ v: Double) -> some View {
        VStack(spacing: 0) {
            Text(store.fmt(v)).font(.caption.monospacedDigit().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: filter + sort

    private var filtered: [WorkItem] {
        let q = search.lowercased()
        let list = store.items.filter { it in
            if activeOnly && it.isFinal { return false }
            if stateFilter != "All" && it.stateName != stateFilter { return false }
            switch sprintFilter {
            case kSprintNone: if !it.sprint.isEmpty { return false }
            case kSprintCurrent, "All": break          // current = server-scoped; All = no predicate
            default: if it.sprint != sprintFilter { return false }
            }
            if !q.isEmpty && !(it.name.lowercased().contains(q) || String(it.id).contains(q)) { return false }
            return true
        }
        return sorted(list)
    }

    private func sorted(_ list: [WorkItem]) -> [WorkItem] {
        let byName: (WorkItem, WorkItem) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        switch sortBy {
        case .name:   return list.sorted(by: byName)
        case .idDesc: return list.sorted { $0.id > $1.id }
        case .idAsc:  return list.sorted { $0.id < $1.id }
        case .type:   return list.sorted { $0.displayType != $1.displayType ? $0.displayType < $1.displayType : byName($0, $1) }
        case .state:  return list.sorted { $0.stateName != $1.stateName ? $0.stateName < $1.stateName : byName($0, $1) }
        case .sprint: return list.sorted {
            let a = $0.sprint.numericPrefix ?? -1, b = $1.sprint.numericPrefix ?? -1
            return a != b ? a > b : byName($0, $1)
        }
        case .hours:  return list.sorted {
            let a = store.hours(for: $0.id), b = store.hours(for: $1.id)
            return a != b ? a > b : byName($0, $1)
        }
        }
    }
}

private extension String {
    /// Leading integer in the string (e.g. "Sprint 42" → 42), for sprint sort.
    var numericPrefix: Int? {
        let digits = drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }
}

struct ItemRow: View {
    @EnvironmentObject var store: AppStore
    let item: WorkItem
    @State private var states: [WorkflowState] = []
    @State private var hrs = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var showSlots = false
    @State private var hovering = false
    @State private var elapsed = "00:00:00"
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var loggedHours: Double { store.hours(for: item.id) }
    private var isBug: Bool { item.entityType == "Bugs" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            metaRow
            logRow
            if showSlots { SlotsView(itemId: item.id) }
        }
        .padding(12)
        .background(trackingBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(store.isTracking(item.id) ? AnyShapeStyle(Color.red.opacity(0.6)) : AnyShapeStyle(.quaternary)))
        .onHover { hovering = $0 }
        .task { states = await store.states(for: item) }
        .onReceive(tick) { _ in if store.isTracking(item.id) { elapsed = Self.hms(store.trackingElapsed()) } }
    }

    private var trackingBackground: some ShapeStyle {
        store.isTracking(item.id) ? AnyShapeStyle(Color.red.opacity(0.08))
                                  : AnyShapeStyle(Color(.windowBackgroundColor).opacity(hovering ? 1 : 0.55))
    }

    private static func hms(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(item.displayType.uppercased())
                .font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
                .background((isBug ? Color.red : Color.blue).gradient)
                .foregroundStyle(.white).clipShape(Capsule())
            Text(item.name).fontWeight(.medium).lineLimit(1)
            Spacer()
            agentButton
            trackButton
            if loggedHours > 0 {
                Button { showSlots.toggle() } label: {
                    Label(store.fmt(loggedHours), systemImage: showSlots ? "chevron.up" : "clock")
                        .font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small).tint(.green)
            }
        }
    }

    private var agentButton: some View {
        Button { AppDelegate.shared?.openAgent(.item(item)) } label: {
            Label(store.agentActive(item.id) ? "Agent running" : "Agent", systemImage: "sparkles").font(.caption)
        }
        .buttonStyle(.bordered).controlSize(.small).tint(.purple)
    }

    private var trackButton: some View {
        let active = store.isTracking(item.id)
        return Button { Task { await store.toggleTracking(item: item) } } label: {
            if active {
                Label("Stop & Log \(elapsed)", systemImage: "stop.fill")
                    .font(.caption.monospacedDigit())
            } else {
                Label("Start", systemImage: "play.fill").font(.caption)
            }
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
        .tint(active ? .red : .accentColor)
        // Disable starting a different task while one is already running, and
        // manual tracking while an agent run is timing this task.
        .disabled((store.isTracking && !active) || (!active && store.agentActive(item.id)))
    }

    private var metaRow: some View {
        HStack(spacing: 10) {
            Button("#\(item.id)") { store.openInTP(item.id) }
                .buttonStyle(.link).font(.caption.monospacedDigit())
            statePicker
            Spacer()
            Label(item.projectName, systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !item.sprint.isEmpty {
                Text(item.sprint).font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule()).foregroundStyle(.blue)
            }
        }
    }

    private var statePicker: some View {
        Menu {
            ForEach(states) { s in
                Button(s.name) { Task { await store.changeState(item: item, to: s) } }
            }
        } label: {
            HStack(spacing: 3) {
                Circle().fill(item.isFinal ? Color.secondary : Color.green).frame(width: 6, height: 6)
                Text(item.stateName).font(.caption)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .foregroundStyle(item.isFinal ? Color.secondary : Color.green)
    }

    private var logRow: some View {
        HStack(spacing: 8) {
            TextField("hrs", text: $hrs).frame(width: 52).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
            DatePicker("", selection: $date, displayedComponents: .date).labelsHidden()
            TextField("Add a note…", text: $note).textFieldStyle(.roundedBorder)
            Button { logNow() } label: {
                Label("Log", systemImage: "plus.circle.fill")
            }.buttonStyle(.borderedProminent)
        }.controlSize(.small)
    }

    private func logNow() {
        guard let h = Double(hrs.replacingOccurrences(of: ",", with: ".")), h > 0 else {
            store.status = "Enter hours > 0"; return
        }
        Task { await store.logTime(entityId: item.id, hours: h, description: note, date: date); hrs = ""; note = "" }
    }
}

/// Per-task time-entry breakdown with inline edit + delete.
struct SlotsView: View {
    @EnvironmentObject var store: AppStore
    let itemId: Int
    var slots: [TimeEntry] { store.times.filter { $0.itemId == itemId }.sorted { $0.day > $1.day } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Time entries", systemImage: "clock.arrow.circlepath")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Total \(store.fmt(slots.reduce(0) { $0 + $1.hours }))")
                    .font(.caption2.bold().monospacedDigit())
            }
            ForEach(slots) { SlotRow(entry: $0) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SlotRow: View {
    @EnvironmentObject var store: AppStore
    let entry: TimeEntry
    @State private var hrs = ""
    @State private var note = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.day).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            TextField("hrs", text: $hrs).frame(width: 50).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
            TextField("note", text: $note).textFieldStyle(.roundedBorder)
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
        a.informativeText = "\(entry.day) · \(store.fmt(entry.hours))"
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { Task { await store.deleteTime(entry) } }
    }
}
