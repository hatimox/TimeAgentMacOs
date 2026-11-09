import Foundation

/// A Task, Bug or User Story assigned to me, plus its parent User Story
/// (a story is its own parent, so it groups with its tasks).
struct WorkItem: Identifiable, Hashable {
    let id: Int
    var name: String
    var entityType: String          // "Tasks" | "Bugs" | "UserStories"
    var displayType: String         // "Task" | "Bug" | "User Story"
    var stateId: Int
    var stateName: String
    var isFinal: Bool
    var projectName: String
    var processId: Int
    var sprint: String
    var usId: Int
    var usName: String

    var isStory: Bool { entityType == "UserStories" }
    var isBug: Bool { entityType == "Bugs" }
    /// Key into the per-process workflow-state map.
    var stateKey: String { isStory ? "UserStory" : isBug ? "Bug" : "Task" }

    static func displayType(for collection: String) -> String {
        switch collection {
        case "Bugs": return "Bug"
        case "UserStories": return "User Story"
        default: return "Task"
        }
    }
}

/// One TP time entry of mine.
struct TimeEntry: Identifiable, Hashable {
    let id: Int
    var itemId: Int
    var hours: Double
    var day: String                 // "YYYY-MM-DD" (offset-aware)
    var description: String
}

/// A selectable workflow state for a process/entity-type.
struct WorkflowState: Identifiable, Hashable {
    let id: Int
    var name: String
    var isFinal: Bool
    var priority: Double
}

/// User-defined meeting shortcut for the end-of-meeting picker.
struct DynamicMeeting: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var taskId: Int
    var description: String
}

/// A recurring auto-logged entry (e.g. dailies).
struct RecurringEntry: Identifiable, Hashable, Codable {
    var id: String
    var label: String
    var taskId: Int
    var hours: Double
}

/// One user-confirmable religious-holiday day off. Slot-keyed ("year|name|idx")
/// so an edited date or toggle persists even when it no longer matches the
/// shipped estimate. Mirrors the Electron `religiousSlots` persistence shape.
struct ReligiousSlot: Identifiable, Hashable, Codable {
    var key: String          // "2026|Eid al-Adha|0"
    var date: String         // YYYY-MM-DD
    var on: Bool             // counts as a day off when true
    var id: String { key }
}
