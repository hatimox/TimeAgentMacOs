import AppKit

/// Native end-of-meeting prompt. Replaces the Electron dialog flow.
/// Daily / [Defined list] / Choose task / Cancel — "Defined list" only shown
/// when dynamic meetings are configured. All native NSAlert/NSPanel, so nothing
/// can freeze a background event loop.
@MainActor
enum MeetingPrompt {
    static func present(store: AppStore, start: Date, end: Date) async {
        let raw = end.timeIntervalSince(start) / 3600
        let defaultHours = (store.billableHours(raw) * 100).rounded() / 100
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let win = "\(f.string(from: start))-\(f.string(from: end))"

        let hasDynamic = !store.settings.dynamicMeetings.isEmpty
        let alert = NSAlert()
        alert.messageText = "Meeting ended (\(win))"
        alert.informativeText = "Hours to log (editable). How should this be logged?"
        let hoursField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        hoursField.stringValue = String(format: "%.2f", defaultHours)
        hoursField.alignment = .right
        alert.accessoryView = hoursField
        alert.addButton(withTitle: "Daily")
        if hasDynamic { alert.addButton(withTitle: "Defined list") }
        alert.addButton(withTitle: "Choose task")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = hoursField
        let resp = alert.runModal()
        let hours = Double(hoursField.stringValue.trimmingCharacters(in: .whitespaces)).map { max(0, $0) } ?? defaultHours

        // Map response → action accounting for the optional Defined-list button.
        var actions = ["daily"]
        if hasDynamic { actions.append("defined") }
        actions.append("choose"); actions.append("cancel")
        let idx = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let action = (idx >= 0 && idx < actions.count) ? actions[idx] : "cancel"

        let required = store.settings.timeDescriptionRequired
        // Each path stays in LogPrompt until the entry saves or is discarded.
        let save: (Int) -> (Double, String) async -> String? = { taskId in
            { h, d in await store.logTime(entityId: taskId, hours: h, description: d, date: start) }
        }
        switch action {
        case "daily":
            let taskId = store.settings.dailyTaskId
            var firstError: String?
            if !required {
                firstError = await save(taskId)(hours, "")
                if firstError == nil { return }
            }
            await LogPrompt.run(store: store, title: "Daily · meeting \(win)", hours: hours,
                                description: "Daily", error: firstError, save: save(taskId))
        case "choose":
            if let pick = TaskPicker.run(items: store.items.filter { !$0.isFinal },
                                         defaultId: store.settings.meetingsTaskId) {
                await LogPrompt.run(store: store, title: "Meeting \(win)", hours: hours,
                                    description: "", save: save(pick))
            } else {
                store.status = "Meeting \(win) ignored"
            }
        case "defined":
            if let m = DefinedPicker.run(meetings: store.settings.dynamicMeetings) {
                await LogPrompt.run(store: store, title: m.name, hours: hours,
                                    description: m.description.isEmpty ? m.name : m.description,
                                    save: save(m.taskId))
            } else {
                store.status = "Meeting \(win) ignored"
            }
        default:
            store.status = "Meeting \(win) ignored"
        }
    }
}

/// Hours + description form for one time entry. Stays open — showing TP's
/// error and keeping what was typed — until `save` succeeds (returns nil) or
/// the user confirms discarding the time.
@MainActor
enum LogPrompt {
    static func run(store: AppStore, title: String, hours: Double, description: String,
                    error: String? = nil, save: (Double, String) async -> String?) async {
        var hoursText = String(format: "%.2f", hours)
        var desc = description
        var lastError = error
        while true {
            let required = store.settings.timeDescriptionRequired
            let a = NSAlert()
            a.messageText = title
            a.informativeText = (lastError.map { "⚠️ \($0)\n\n" } ?? "")
                + (required ? "Hours and description (required)." : "Hours and description (optional).")
            if lastError != nil { a.alertStyle = .warning }
            a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")

            let hoursField = NSTextField(frame: NSRect(x: 0, y: 32, width: 90, height: 24))
            hoursField.stringValue = hoursText; hoursField.alignment = .right
            let descField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            descField.stringValue = desc
            descField.placeholderString = required ? "Description (required)" : "Description"
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
            box.addSubview(hoursField); box.addSubview(descField)
            a.accessoryView = box
            NSApp.activate(ignoringOtherApps: true)
            a.window.initialFirstResponder = descField

            let resp = a.runModal()
            hoursText = hoursField.stringValue
            desc = descField.stringValue
            if resp != .alertFirstButtonReturn {
                if confirmDiscard(hoursText) { store.status = "Not logged: \(title)"; return }
                continue
            }
            guard let h = Double(hoursText.trimmingCharacters(in: .whitespaces)
                                    .replacingOccurrences(of: ",", with: ".")), h > 0 else {
                lastError = "Enter hours greater than 0."; continue
            }
            if required && desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastError = "A description is required."; continue
            }
            lastError = await save(h, desc)
            if lastError == nil { return }
        }
    }

    private static func confirmDiscard(_ hours: String) -> Bool {
        let a = NSAlert()
        a.messageText = "Discard this time entry?"
        a.informativeText = "\(hours) h will not be logged to TargetProcess."
        a.addButton(withTitle: "Keep editing"); a.addButton(withTitle: "Discard")
        return a.runModal() == .alertSecondButtonReturn
    }
}

/// Pick an active task by search. Returns the chosen task id, or nil.
@MainActor
enum TaskPicker {
    static func run(items: [WorkItem], defaultId: Int) -> Int? {
        // A lightweight searchable list in an NSAlert accessory.
        let a = NSAlert()
        a.messageText = "Choose the task to log to"
        a.informativeText = "Pick from your active tasks."
        a.addButton(withTitle: "Select"); a.addButton(withTitle: "Cancel")
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for it in items { pop.addItem(withTitle: "#\(it.id) — \(it.name)"); pop.lastItem?.tag = it.id }
        if defaultId != 0, let idx = items.firstIndex(where: { $0.id == defaultId }) { pop.selectItem(at: idx) }
        a.accessoryView = pop
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let tag = pop.selectedItem?.tag ?? 0
        return tag != 0 ? tag : (defaultId != 0 ? defaultId : nil)
    }
}

/// Pick a configured dynamic meeting. Returns the meeting, or nil.
@MainActor
enum DefinedPicker {
    static func run(meetings: [DynamicMeeting]) -> DynamicMeeting? {
        let a = NSAlert()
        a.messageText = "Select a meeting"
        a.addButton(withTitle: "Select"); a.addButton(withTitle: "Cancel")
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for m in meetings { pop.addItem(withTitle: "\(m.name) (#\(m.taskId))") }
        a.accessoryView = pop
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let i = pop.indexOfSelectedItem
        return (i >= 0 && i < meetings.count) ? meetings[i] : nil
    }
}
