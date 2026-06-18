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
        }
        .formStyle(.grouped)
    }

    private var meetings: some View {
        Form {
            Section("Task ids") {
                TextField("Daily task id", value: $store.settings.dailyTaskId, format: .number)
                TextField("Meetings task id", value: $store.settings.meetingsTaskId, format: .number)
            }
            Section("Rounding") {
                TextField("Minimum minutes", value: $store.settings.meetingMinMinutes, format: .number)
                TextField("Step minutes", value: $store.settings.meetingStepMinutes, format: .number)
                Text("Rounds up to the minimum, then in step increments.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dynamic meeting shortcuts") {
                if store.settings.dynamicMeetings.isEmpty {
                    Text("No shortcuts yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    columnHeader(["Name": nil, "Task id": 88])
                    ForEach($store.settings.dynamicMeetings) { $m in
                        HStack(spacing: 10) {
                            TextField("e.g. Standup", text: $m.name).textFieldStyle(.roundedBorder)
                            TextField("0", value: $m.taskId, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 88).multilineTextAlignment(.trailing)
                            removeButton { store.settings.dynamicMeetings.removeAll { $0.id == m.id } }
                        }
                    }
                }
                Button { store.settings.dynamicMeetings.append(.init(id: UUID().uuidString, name: "", taskId: 0, description: "")) }
                    label: { Label("Add meeting", systemImage: "plus.circle.fill") }.buttonStyle(.borderless)
            }
            saveButton { store.settings.save() }
        }
        .formStyle(.grouped)
    }

    private var recurring: some View {
        Form {
            Section {
                if store.settings.recurring.isEmpty {
                    Text("No recurring entries yet. Add one to auto-log it each working day.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    columnHeader(["Label": nil, "Task id": 88, "Hours": 64])
                    ForEach($store.settings.recurring) { $r in
                        HStack(spacing: 10) {
                            TextField("e.g. Daily standup", text: $r.label).textFieldStyle(.roundedBorder)
                            TextField("0", value: $r.taskId, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 88).multilineTextAlignment(.trailing)
                            TextField("0", value: $r.hours, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
                            removeButton { store.settings.recurring.removeAll { $0.id == r.id } }
                        }
                    }
                }
                Button { store.settings.recurring.append(.init(id: UUID().uuidString, label: "", taskId: 0, hours: 1)) }
                    label: { Label("Add recurring", systemImage: "plus.circle.fill") }.buttonStyle(.borderless)
            } header: { Text("Recurring entries") } footer: {
                Text("Auto-logged once per working day on launch, skipping weekly days off and holidays.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            saveButton { store.settings.save() }
        }
        .formStyle(.grouped)
    }

    /// A caption row labelling the columns of an editable list, so the bare
    /// text fields below it read clearly. Pass [title: fixedWidth?]; a nil width
    /// means the column flexes (matching a non-fixed TextField).
    private func columnHeader(_ cols: KeyValuePairs<String, CGFloat?>) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(cols), id: \.key) { title, width in
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: width, alignment: width == nil ? .leading : .trailing)
                    .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            }
            Color.clear.frame(width: 22)   // aligns over the remove button
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle.fill")
        }
        .buttonStyle(.borderless).foregroundStyle(.red).frame(width: 22)
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
