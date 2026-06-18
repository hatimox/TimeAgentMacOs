import AppKit

/// Native end-of-meeting prompt. Replaces the Electron dialog flow.
/// Daily / [Defined list] / Choose task / Cancel — "Defined list" only shown
/// when dynamic meetings are configured. All native NSAlert/NSPanel, so nothing
/// can freeze a background event loop.
@MainActor
enum MeetingPrompt {
    static func present(store: AppStore, start: Date, end: Date) async {
        let raw = end.timeIntervalSince(start) / 3600
        let hours = (store.billableHours(raw) * 100).rounded() / 100
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let win = "\(f.string(from: start))-\(f.string(from: end))"

        let hasDynamic = !store.settings.dynamicMeetings.isEmpty
        let alert = NSAlert()
        alert.messageText = "Meeting ended (\(win), \(String(format: "%.2f", hours))h)"
        alert.informativeText = "How should this be logged?"
        alert.addButton(withTitle: "Daily")
        if hasDynamic { alert.addButton(withTitle: "Defined list") }
        alert.addButton(withTitle: "Choose task")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()

        // Map response → action accounting for the optional Defined-list button.
        var actions = ["daily"]
        if hasDynamic { actions.append("defined") }
        actions.append("choose"); actions.append("cancel")
        let idx = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let action = (idx >= 0 && idx < actions.count) ? actions[idx] : "cancel"

        switch action {
        case "daily":
            await store.logTime(entityId: store.settings.dailyTaskId, hours: hours, description: "", date: start)
        case "choose":
            if let pick = TaskPicker.run(items: store.items.filter { !$0.isFinal },
                                         defaultId: store.settings.meetingsTaskId) {
                let desc = TextPrompt.run(title: "Meeting \(win)", message: "Description (optional)")
                if let desc { await store.logTime(entityId: pick, hours: hours, description: desc, date: start) }
            }
        case "defined":
            if let m = DefinedPicker.run(meetings: store.settings.dynamicMeetings) {
                let desc = TextPrompt.run(title: m.name, message: "Description (editable)", initial: m.description)
                if let desc { await store.logTime(entityId: m.taskId, hours: hours, description: desc, date: start) }
            }
        default:
            store.status = "Meeting \(win) ignored"
        }
    }
}

/// Simple text input via NSAlert + accessory field. Returns nil if cancelled.
@MainActor
enum TextPrompt {
    static func run(title: String, message: String, initial: String = "") -> String? {
        let a = NSAlert(); a.messageText = title; a.informativeText = message
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Skip")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        a.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = field
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
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
