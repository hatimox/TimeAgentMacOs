import Foundation

/// Persisted settings, stored as JSON in the same Application Support dir the
/// Electron app used (~/Library/Application Support/TimeAgent/settings.json), so
/// an existing config is picked up. The token lives in the Keychain, not here.
final class Settings: ObservableObject {
    @Published var tpURL: String = ""
    @Published var myUserId: Int = 0
    @Published var myUserName: String = ""
    @Published var myUserEmail: String = ""
    @Published var timezone: String = TimeZone.current.identifier
    @Published var dailyTaskId: Int = 0
    @Published var meetingsTaskId: Int = 0
    @Published var meetingMinMinutes: Int = 30
    @Published var meetingStepMinutes: Int = 15
    @Published var recurring: [RecurringEntry] = []
    @Published var dynamicMeetings: [DynamicMeeting] = []
    @Published var daysOff: [String] = []
    @Published var weeklyOff: [Int] = [0, 6]
    @Published var region: String = "none"
    @Published var religiousSlots: [ReligiousSlot] = []
    @Published var token: String = ""

    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TimeAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    private var file: URL { Self.dir.appendingPathComponent("settings.json") }

    var isConfigured: Bool { !token.isEmpty && tpURL.hasPrefix("http") }

    init() { load() }

    func load() {
        token = Keychain.readToken() ?? ""
        guard let data = try? Data(contentsOf: file),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        tpURL = j["tpURL"] as? String ?? tpURL
        myUserId = j["myUserId"] as? Int ?? 0
        myUserName = j["myUserName"] as? String ?? ""
        myUserEmail = j["myUserEmail"] as? String ?? ""
        timezone = j["timezone"] as? String ?? timezone
        dailyTaskId = j["dailyTaskId"] as? Int ?? 0
        meetingsTaskId = j["meetingsTaskId"] as? Int ?? 0
        meetingMinMinutes = j["meetingMinMinutes"] as? Int ?? 30
        meetingStepMinutes = j["meetingStepMinutes"] as? Int ?? 15
        weeklyOff = j["weeklyOff"] as? [Int] ?? [0, 6]
        daysOff = j["daysOff"] as? [String] ?? []
        region = j["region"] as? String ?? "none"
        if let slots = j["religiousSlots"] as? [[String: Any]] {
            religiousSlots = slots.compactMap {
                guard let key = $0["key"] as? String, let date = $0["date"] as? String else { return nil }
                return ReligiousSlot(key: key, date: date, on: $0["on"] as? Bool ?? true)
            }
        }
        if let recs = j["recurring"] as? [[String: Any]] {
            recurring = recs.map {
                RecurringEntry(id: $0["id"] as? String ?? UUID().uuidString,
                               label: $0["label"] as? String ?? "",
                               taskId: $0["taskId"] as? Int ?? 0,
                               hours: $0["hours"] as? Double ?? 1)
            }
        }
        if let dyn = j["dynamicMeetings"] as? [[String: Any]] {
            dynamicMeetings = dyn.map {
                DynamicMeeting(id: $0["id"] as? String ?? UUID().uuidString,
                               name: $0["name"] as? String ?? "",
                               taskId: $0["taskId"] as? Int ?? 0,
                               description: $0["description"] as? String ?? "")
            }
        }
    }

    func save() {
        Keychain.writeToken(token)
        var j: [String: Any] = [
            "tpURL": tpURL, "myUserId": myUserId, "myUserName": myUserName,
            "myUserEmail": myUserEmail, "timezone": timezone,
            "dailyTaskId": dailyTaskId, "meetingsTaskId": meetingsTaskId,
            "meetingMinMinutes": meetingMinMinutes, "meetingStepMinutes": meetingStepMinutes,
            "weeklyOff": weeklyOff, "daysOff": daysOff, "region": region,
        ]
        j["religiousSlots"] = religiousSlots.map { ["key": $0.key, "date": $0.date, "on": $0.on] }
        j["recurring"] = recurring.map { ["id": $0.id, "label": $0.label, "taskId": $0.taskId, "hours": $0.hours] }
        j["dynamicMeetings"] = dynamicMeetings.map { ["id": $0.id, "name": $0.name, "taskId": $0.taskId, "description": $0.description] }
        if let data = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) {
            try? data.write(to: file)
        }
    }

    /// Minutes east of UTC for the configured timezone (TP date anchoring).
    var tzOffsetMinutes: Int {
        (TimeZone(identifier: timezone) ?? .current).secondsFromGMT() / 60
    }
}
