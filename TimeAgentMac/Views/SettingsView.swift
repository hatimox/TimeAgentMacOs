import SwiftUI

/// Settings — TP connection, meeting task ids/rounding, recurring entries, and
/// dynamic meeting shortcuts. Mirrors the Electron settings tabs.
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var url = ""
    @State private var token = ""
    @State private var holYear = Calendar.current.component(.year, from: Date())
    @State private var newDayOff = ""
    @State private var showSaved = false

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        TabView {
            account.tabItem { Label("Account", systemImage: "person.crop.circle") }
            meetings.tabItem { Label("Meetings", systemImage: "video") }
            recurring.tabItem { Label("Recurring", systemImage: "repeat") }
            daysOff.tabItem { Label("Days off", systemImage: "calendar") }
        }
        .frame(width: 500, height: 470).padding()
        .onAppear { url = store.settings.tpURL; token = store.settings.token }
    }

    /// A trailing "Saved" confirmation that fades after a moment.
    private func saveButton(_ action: @escaping () -> Void) -> some View {
        HStack {
            Button { action(); flashSaved() } label: {
                Label("Save", systemImage: "checkmark.circle.fill")
            }.buttonStyle(.borderedProminent)
            if showSaved {
                Label("Saved", systemImage: "checkmark").font(.caption)
                    .foregroundStyle(.green).transition(.opacity)
            }
            Spacer()
        }
    }

    private func flashSaved() {
        withAnimation { showSaved = true }
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); withAnimation { showSaved = false } }
    }

    private var account: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AvatarView(name: store.settings.myUserName.isEmpty ? "?" : store.settings.myUserName,
                               email: store.settings.myUserEmail, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        if store.settings.myUserId != 0 {
                            Text(store.settings.myUserName).font(.headline)
                            Text(store.settings.myUserEmail.isEmpty ? "id \(store.settings.myUserId)" : store.settings.myUserEmail)
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Not signed in").font(.headline)
                            Text("Enter your instance URL and token below.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            Section("Connection") {
                TextField("Instance URL", text: $url, prompt: Text("https://company.tpondemand.com"))
                SecureField("API token", text: $token)
            }
            saveButton {
                let changed = token != store.settings.token || url != store.settings.tpURL
                store.settings.tpURL = url; store.settings.token = token
                if changed { store.settings.myUserId = 0; store.settings.myUserName = ""; store.settings.myUserEmail = "" }
                store.settings.save(); store.rebuildClient()
                Task { await store.startup() }
            }
            Text("Token: TargetProcess → My Profile → Access Tokens. Stored in the Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            Section {
                HStack { Text("Version").foregroundStyle(.secondary); Spacer(); Text(AppInfo.version).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private var meetings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                groupCard("Task ids") {
                    labeledField("Daily task id") {
                        TextField("0", value: $store.settings.dailyTaskId, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 120)
                    }
                    labeledField("Meetings task id") {
                        TextField("0", value: $store.settings.meetingsTaskId, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 120)
                    }
                }
                groupCard("Rounding") {
                    labeledField("Minimum minutes") {
                        TextField("0", value: $store.settings.meetingMinMinutes, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 120)
                    }
                    labeledField("Step minutes") {
                        TextField("0", value: $store.settings.meetingStepMinutes, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 120)
                    }
                    Text("Rounds up to the minimum, then in step increments.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                groupCard("Dynamic meeting shortcuts") {
                    if store.settings.dynamicMeetings.isEmpty {
                        Text("No shortcuts yet.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        columnHeaders([("Name", nil), ("Task id", 90)])
                        Divider()
                        ForEach($store.settings.dynamicMeetings) { $m in
                            entryRow(onRemove: { store.settings.dynamicMeetings.removeAll { $0.id == m.id } }) {
                                TextField("Standup", text: $m.name)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                                TextField("0", value: $m.taskId, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    Button { store.settings.dynamicMeetings.append(.init(id: UUID().uuidString, name: "", taskId: 0, description: "")) }
                        label: { Label("Add meeting", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                saveButton { store.settings.save() }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    /// A titled bordered card grouping related controls (plain-layout analogue
    /// of a Form Section).
    private func groupCard<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    /// A "label … field" row with the label leading and field trailing.
    private func labeledField<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack { Text(title); Spacer(); content() }
    }

    private var recurring: some View {
        editableList(
            title: "Recurring entries",
            footer: "Auto-logged once per working day on launch, skipping weekly days off and holidays.",
            empty: "No recurring entries yet. Add one to auto-log it each working day.",
            isEmpty: store.settings.recurring.isEmpty,
            columns: columnHeaders([("Label", nil), ("Task id", 90), ("Hours", 64)]),
            add: { store.settings.recurring.append(.init(id: UUID().uuidString, label: "", taskId: 0, hours: 1)) },
            addTitle: "Add recurring"
        ) {
            ForEach($store.settings.recurring) { $r in
                entryRow(onRemove: { store.settings.recurring.removeAll { $0.id == r.id } }) {
                    TextField("Daily standup", text: $r.label)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                    TextField("0", value: $r.taskId, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
                    TextField("0", value: $r.hours, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
                }
            }
        }
    }

    // MARK: editable-list building blocks (plain layout — NOT a Form, so
    // TextFields keep their in-field placeholders and gain no phantom labels)

    /// A captioned column-header row aligned to the field widths below it.
    private func columnHeaders(_ cols: [(String, CGFloat?)]) -> some View {
        HStack(spacing: 10) {
            ForEach(cols, id: \.0) { title, width in
                Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: width, alignment: width == nil ? .leading : .trailing)
                    .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            }
            Color.clear.frame(width: 24)   // sits over the remove button
        }
    }

    /// One editable row: the given fields in an HStack plus a trailing remove.
    private func entryRow<Content: View>(onRemove: @escaping () -> Void,
                                         @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }.buttonStyle(.borderless).foregroundStyle(.red).frame(width: 24)
        }
    }

    /// A self-contained editable list tab: header, bordered card of rows, an
    /// add button, and a Save button — built from plain stacks, not a Form.
    private func editableList<Rows: View>(
        title: String, footer: String, empty: String, isEmpty: Bool,
        columns: some View, add: @escaping () -> Void, addTitle: String,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                VStack(alignment: .leading, spacing: 10) {
                    if isEmpty {
                        Text(empty).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        columns
                        Divider()
                        rows()
                    }
                    Button(action: add) {
                        Label(addTitle, systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                Text(footer).font(.caption).foregroundStyle(.secondary)

                saveButton { store.settings.save() }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    // MARK: Days off

    private var daysOff: some View {
        Form {
            Picker("Region", selection: $store.settings.region) {
                Text("None").tag("none")
                Text("Morocco").tag("morocco")
            }
            Text("Morocco applies the fixed civil holidays automatically.")
                .font(.caption).foregroundStyle(.secondary)

            Section("Weekly off") {
                HStack {
                    ForEach(0..<7, id: \.self) { d in
                        Toggle(Self.weekdayNames[d], isOn: weeklyOffBinding(d))
                            .toggleStyle(.button).controlSize(.small)
                    }
                }
            }

            Section("Specific days off") {
                ForEach(store.settings.daysOff, id: \.self) { day in
                    HStack {
                        Text(day)
                        Spacer()
                        Button(role: .destructive) { store.settings.daysOff.removeAll { $0 == day } }
                            label: { Image(systemName: "xmark") }
                    }
                }
                HStack {
                    TextField("YYYY-MM-DD", text: $newDayOff)
                    Button("Add") {
                        let d = newDayOff.trimmingCharacters(in: .whitespaces)
                        if d.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                           !store.settings.daysOff.contains(d) {
                            store.settings.daysOff.append(d); store.settings.daysOff.sort()
                        }
                        newDayOff = ""
                    }
                }
            }

            if store.settings.region == "morocco" {
                Section {
                    Stepper("Year: \(holYear)", value: $holYear, in: 2026...2030)
                } header: { Text("Holiday year") } footer: {
                    Text("Public + religious holidays below are skipped for recurring auto-logging when Morocco is selected.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Public holidays (fixed)") {
                    ForEach(Holidays.fixedHolidaysNamed(holYear), id: \.date) { h in
                        HStack {
                            Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.secondary)
                            Text(h.name)
                            Spacer()
                            Text(h.date).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Religious holidays (estimates — confirm/adjust)") {
                    let slots = Holidays.religiousHolidays(holYear)
                    if slots.isEmpty {
                        Text("No estimates for \(holYear). Add specific days off above.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, entry in
                        ForEach(Array(entry.dates.enumerated()), id: \.offset) { i, estimate in
                            religiousRow(name: entry.name, multi: entry.dates.count > 1,
                                         dayIdx: i, estimate: estimate)
                        }
                    }
                }
            }

            saveButton { store.settings.save() }
        }
        .formStyle(.grouped)
    }

    /// One editable religious-holiday day. Identified by a stable slot key
    /// (year|name|idx) so a user's edit/toggle persists across reloads.
    private func religiousRow(name: String, multi: Bool, dayIdx: Int, estimate: String) -> some View {
        let key = "\(holYear)|\(name)|\(dayIdx)"
        return HStack {
            Toggle("", isOn: religiousOnBinding(key: key, estimate: estimate)).labelsHidden()
            Text(name + (multi ? " (day \(dayIdx + 1))" : ""))
            Spacer()
            TextField("YYYY-MM-DD", text: religiousDateBinding(key: key, estimate: estimate))
                .frame(width: 120)
        }
    }

    // MARK: bindings

    private func weeklyOffBinding(_ d: Int) -> Binding<Bool> {
        Binding(
            get: { store.settings.weeklyOff.contains(d) },
            set: { on in
                if on { if !store.settings.weeklyOff.contains(d) { store.settings.weeklyOff.append(d) } }
                else { store.settings.weeklyOff.removeAll { $0 == d } }
            })
    }

    private func slot(_ key: String) -> ReligiousSlot? { store.settings.religiousSlots.first { $0.key == key } }

    private func updateSlot(key: String, estimate: String, _ mutate: (inout ReligiousSlot) -> Void) {
        if let idx = store.settings.religiousSlots.firstIndex(where: { $0.key == key }) {
            mutate(&store.settings.religiousSlots[idx])
        } else {
            var s = ReligiousSlot(key: key, date: estimate, on: true)
            mutate(&s)
            store.settings.religiousSlots.append(s)
        }
    }

    private func religiousOnBinding(key: String, estimate: String) -> Binding<Bool> {
        Binding(
            get: { slot(key)?.on ?? true },
            set: { v in updateSlot(key: key, estimate: estimate) { $0.on = v } })
    }

    private func religiousDateBinding(key: String, estimate: String) -> Binding<String> {
        Binding(
            get: { slot(key)?.date ?? estimate },
            set: { v in updateSlot(key: key, estimate: estimate) { $0.date = v } })
    }
}
