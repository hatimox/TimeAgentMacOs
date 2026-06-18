import Foundation

/// TargetProcess REST client — a faithful port of the Electron tpclient.js,
/// including the noon-anchored writes, offset-aware day bucketing, manual
/// query-string encoding, and skip-based pagination (TP caps `take` at 1000).
struct TPError: Error { let message: String }

final class TPClient {
    let baseURL: String
    let token: String
    var myUserId: Int

    init(baseURL: String, token: String, myUserId: Int) {
        self.baseURL = baseURL.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        self.token = token
        self.myUserId = myUserId
    }

    // MARK: - low-level

    private func makeURL(_ path: String, _ query: [String: String]) -> URL {
        var params = ["format": "json", "access_token": token]
        for (k, v) in query { params[k] = v }
        let qs = params.map { k, v in
            "\(encode(k))=\(encode(v))"
        }.joined(separator: "&")
        return URL(string: "\(baseURL)/api/v1/\(path)?\(qs)")!
    }

    // %20 for spaces (TP's OData parser rejects '+').
    private func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func request(_ method: String, _ url: URL, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TPError(message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw TPError(message: "HTTP \(http.statusCode): \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TPError(message: "Bad JSON")
        }
        return obj
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        try await request("GET", makeURL(path, query))
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await request("POST", makeURL(path, [:]), body: body)
    }

    /// Page through a collection until exhausted (TP caps a page at 1000).
    private func getAllItems(_ path: String, _ query: [String: String]) async throws -> [[String: Any]] {
        let take = 1000
        var items: [[String: Any]] = []
        var skip = 0
        while true {
            var q = query
            q["take"] = String(take); q["skip"] = String(skip)
            let obj = try await get(path, q)
            let batch = obj["Items"] as? [[String: Any]] ?? []
            items.append(contentsOf: batch)
            if batch.count < take || batch.isEmpty { break }
            skip += take
        }
        return items
    }

    // MARK: - identity

    struct Me { let id: Int; let name: String; let email: String }
    func whoAmI() async throws -> Me {
        let obj = try await get("Context", [:])
        guard let u = obj["LoggedUser"] as? [String: Any], let id = u["Id"] as? Int else {
            throw TPError(message: "Could not read logged-in user from token")
        }
        let name = "\(u["FirstName"] as? String ?? "") \(u["LastName"] as? String ?? "")".trimmingCharacters(in: .whitespaces)
        return Me(id: id, name: name, email: u["Email"] as? String ?? "")
    }

    // MARK: - items

    func fetchAllAssigned(currentSprintOnly: Bool) async throws -> [WorkItem] {
        async let tasks = fetchCollection("Tasks", currentSprintOnly)
        async let bugs = fetchCollection("Bugs", currentSprintOnly)
        let all = try await tasks + bugs
        return all.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func fetchCollection(_ collection: String, _ currentSprintOnly: Bool) async throws -> [WorkItem] {
        var whereClause = "AssignedUser.Id eq \(myUserId)"
        if currentSprintOnly { whereClause += " and (TeamIteration.IsCurrent eq 'true')" }
        let items = try await getAllItems(collection, [
            "where": whereClause,
            "include": "[Id,Name,EntityState[Id,Name,IsFinal],Project[Name,Process[Id]],TeamIteration[Name],UserStory[Id,Name]]",
        ])
        return items.compactMap { it in
            guard let id = it["Id"] as? Int else { return nil }
            let es = it["EntityState"] as? [String: Any] ?? [:]
            let project = it["Project"] as? [String: Any] ?? [:]
            let process = project["Process"] as? [String: Any] ?? [:]
            let us = it["UserStory"] as? [String: Any] ?? [:]
            return WorkItem(
                id: id, name: it["Name"] as? String ?? "",
                entityType: collection, displayType: collection == "Bugs" ? "Bug" : "Task",
                stateId: es["Id"] as? Int ?? 0, stateName: es["Name"] as? String ?? "?",
                isFinal: es["IsFinal"] as? Bool ?? false,
                projectName: project["Name"] as? String ?? "",
                processId: process["Id"] as? Int ?? 0,
                sprint: (it["TeamIteration"] as? [String: Any])?["Name"] as? String ?? "",
                usId: us["Id"] as? Int ?? 0, usName: us["Name"] as? String ?? "")
        }
    }

    func fetchProcessStates(processId: Int) async throws -> [String: [WorkflowState]] {
        var out: [String: [WorkflowState]] = ["Task": [], "Bug": []]
        guard processId != 0 else { return out }
        for etype in ["Task", "Bug"] {
            guard let obj = try? await get("EntityStates", [
                "where": "(Process.Id eq \(processId)) and (EntityType.Name eq '\(etype)')",
                "include": "[Id,Name,NumericPriority,IsFinal]", "take": "200",
            ]) else { continue }
            let items = obj["Items"] as? [[String: Any]] ?? []
            out[etype] = items.compactMap {
                guard let id = $0["Id"] as? Int else { return nil }
                return WorkflowState(id: id, name: $0["Name"] as? String ?? "",
                                     isFinal: $0["IsFinal"] as? Bool ?? false,
                                     priority: $0["NumericPriority"] as? Double ?? 0)
            }.sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }
        }
        return out
    }

    func setEntityState(entityType: String, entityId: Int, stateId: Int) async throws -> (name: String, isFinal: Bool) {
        let resp = try await post("\(entityType)/\(entityId)", ["EntityState": ["Id": stateId]])
        let es = resp["EntityState"] as? [String: Any] ?? [:]
        return (es["Name"] as? String ?? "?", es["IsFinal"] as? Bool ?? false)
    }

    // MARK: - times

    func fetchMyTimes() async throws -> [TimeEntry] {
        let items = try await getAllItems("Times", [
            "where": "User.Id eq \(myUserId)",
            "include": "[Id,Spent,Date,Description,Assignable[Id]]",
        ])
        return items.compactMap { t in
            guard let id = t["Id"] as? Int else { return nil }
            let itemId = (t["Assignable"] as? [String: Any])?["Id"] as? Int ?? 0
            let hours = (t["Spent"] as? Double) ?? Double(t["Spent"] as? Int ?? 0)
            guard let day = Self.tpDay(t["Date"] as? String) else { return nil }
            return TimeEntry(id: id, itemId: itemId, hours: hours, day: day,
                             description: t["Description"] as? String ?? "")
        }
    }

    @discardableResult
    func logTime(entityId: Int, hours: Double, description: String, date: Date, tzOffsetMinutes: Int) async throws -> Int {
        let body = timeBody(hours: hours, description: description, date: date, tz: tzOffsetMinutes, entityId: entityId)
        let resp = try await post("Times", body)
        guard let id = resp["Id"] as? Int else { throw TPError(message: "Time entry not created") }
        return id
    }

    func updateTime(timeId: Int, hours: Double?, description: String?, date: Date?, tzOffsetMinutes: Int) async throws {
        var body: [String: Any] = [:]
        if let hours { body["Spent"] = hours }
        if let description { body["Description"] = description }
        if let date { body["Date"] = Self.dateString(date, tz: tzOffsetMinutes) }
        _ = try await post("Times/\(timeId)", body)
    }

    func deleteTime(timeId: Int) async throws {
        _ = try await request("DELETE", makeURL("Times/\(timeId)", [:]))
    }

    private func timeBody(hours: Double, description: String, date: Date, tz: Int, entityId: Int) -> [String: Any] {
        var body: [String: Any] = [
            "Spent": hours, "Remain": 0,
            "Date": Self.dateString(date, tz: tz),
            "Assignable": ["Id": entityId],
        ]
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { body["Description"] = d }
        return body
    }

    // MARK: - date helpers (must match the Electron noon-anchor logic exactly)

    /// "/Date(ms±HHMM)/" anchored to noon on the target calendar day, so a ±offset
    /// disagreement with the server can never push the entry across midnight.
    static func dateString(_ date: Date, tz offMin: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: offMin * 60) ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        var noon = DateComponents()
        noon.year = c.year; noon.month = c.month; noon.day = c.day; noon.hour = 12
        let noonUTC = utc.date(from: noon)!
        let ms = Int64(noonUTC.timeIntervalSince1970 * 1000) - Int64(offMin) * 60_000
        let sign = offMin >= 0 ? "+" : "-"
        let a = abs(offMin)
        let off = String(format: "%@%02d%02d", sign, a / 60, a % 60)
        return "/Date(\(ms)\(off))/"
    }

    /// Parse "/Date(ms±HHMM)/" → "YYYY-MM-DD" using the EMBEDDED offset.
    static func tpDay(_ s: String?) -> String? {
        guard let s else { return nil }
        guard let msMatch = s.range(of: "-?\\d{10,}", options: .regularExpression) else { return nil }
        guard let ms = Int64(s[msMatch]) else { return nil }
        var offSec: Int64 = 0
        if let offMatch = s.range(of: "[+-]\\d{4}", options: .regularExpression) {
            let o = String(s[offMatch])
            let sign: Int64 = o.first == "-" ? -1 : 1
            let h = Int64(o.dropFirst().prefix(2)) ?? 0
            let m = Int64(o.dropFirst(3).prefix(2)) ?? 0
            offSec = sign * (h * 3600 + m * 60)
        }
        let shifted = Date(timeIntervalSince1970: Double(ms) / 1000 + Double(offSec))
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
