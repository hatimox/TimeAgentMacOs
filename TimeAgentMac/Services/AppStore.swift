import Foundation
import SwiftUI
import Combine

/// App-wide state + orchestration. Owns the settings, TP client, item/time
/// caches, and the meeting watcher.
@MainActor
final class AppStore: ObservableObject {
    @Published var settings = Settings()
    @Published var items: [WorkItem] = []
    @Published var times: [TimeEntry] = []
    @Published var statesByProcess: [Int: [String: [WorkflowState]]] = [:]
    @Published var status = ""
    @Published var scopeAll = false       // false = current sprint only
    @Published var loading = false

    let watcher = MeetingWatcher()
    private var client: TPClient?
    private var settingsObserver: AnyCancellable?

    init() {
        // Forward nested Settings changes so views observing the store redraw
        // when e.g. a recurring/dynamic entry is added or removed.
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        rebuildClient()
        watcher.minSeconds = Double(max(0, settings.meetingMinMinutes == 0 ? 1 : 60))
        watcher.onMeetingEnded = { [weak self] start, end in
            await self?.handleMeetingEnded(start: start, end: end)
        }
    }

    func rebuildClient() {
        guard settings.isConfigured else { client = nil; return }
        client = TPClient(baseURL: settings.tpURL, token: settings.token, myUserId: settings.myUserId)
    }

    func startup() async {
        guard settings.isConfigured else { return }
        await ensureUser()
        watcher.start()
        await refresh()
        await logRecurringIfDue()   // fire today's recurring auto-logs once
    }

    private func ensureUser() async {
        guard let client, settings.myUserId == 0 || settings.myUserName.isEmpty else { return }
        if let me = try? await client.whoAmI() {
            settings.myUserId = me.id; settings.myUserName = me.name; settings.myUserEmail = me.email
            client.myUserId = me.id
            settings.save()
        }
    }

    func refresh() async {
        guard let client else { return }
        loading = true; status = "Loading…"
        do {
            async let its = client.fetchAllAssigned(currentSprintOnly: !scopeAll)
            async let tms = client.fetchMyTimes()
            items = try await its
            times = try await tms
            status = "Loaded \(items.count) items\(scopeAll ? "" : " (current sprint)")"
        } catch {
            status = "Load failed: \((error as? TPError)?.message ?? error.localizedDescription)"
        }
        loading = false
    }

    func hours(for itemId: Int) -> Double { times.filter { $0.itemId == itemId }.reduce(0) { $0 + $1.hours } }

    // MARK: time logging

    func logTime(entityId: Int, hours: Double, description: String, date: Date) async {
        guard let client else { status = "Not configured"; return }
        status = "Logging…"
        do {
            _ = try await client.logTime(entityId: entityId, hours: hours, description: description,
                                         date: date, tzOffsetMinutes: settings.tzOffsetMinutes)
            status = "Logged \(fmt(hours)) to #\(entityId)"
            await refresh()
        } catch { status = "Log failed: \(msg(error))" }
    }

    func updateTime(_ entry: TimeEntry, hours: Double, description: String, dayISO: String) async {
        guard let client else { return }
        let date = isoDate(dayISO) ?? Date()
        do {
            try await client.updateTime(timeId: entry.id, hours: hours, description: description,
                                        date: date, tzOffsetMinutes: settings.tzOffsetMinutes)
            status = "Time entry updated"; await refresh()
        } catch { status = "Save failed: \(msg(error))" }
    }

    func deleteTime(_ entry: TimeEntry) async {
        guard let client else { return }
        do { try await client.deleteTime(timeId: entry.id); status = "Time entry deleted"; await refresh() }
        catch { status = "Delete failed: \(msg(error))" }
    }

    // MARK: status change

    func states(for item: WorkItem) async -> [WorkflowState] {
        guard let client else { return [] }
        if let cached = statesByProcess[item.processId] {
            return (item.entityType == "Bugs" ? cached["Bug"] : cached["Task"]) ?? []
        }
        if let fetched = try? await client.fetchProcessStates(processId: item.processId) {
            statesByProcess[item.processId] = fetched
            return (item.entityType == "Bugs" ? fetched["Bug"] : fetched["Task"]) ?? []
        }
        return []
    }

    func changeState(item: WorkItem, to state: WorkflowState) async {
        guard let client else { return }
        do {
            let r = try await client.setEntityState(entityType: item.entityType, entityId: item.id, stateId: state.id)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].stateId = state.id; items[idx].stateName = r.name; items[idx].isFinal = r.isFinal
            }
            status = "#\(item.id) → \(r.name)"
        } catch { status = "Status change failed: \(msg(error))" }
    }

    // MARK: meeting end + recurring

    private func handleMeetingEnded(start: Date, end: Date) async {
        await MeetingPrompt.present(store: self, start: start, end: end)
    }

    /// Log every configured recurring entry once per working day (skipping
    /// weekly days off + holidays), deduped via the ledger. Safe to call
    /// repeatedly: it no-ops on days off and already-logged entries.
    func logRecurringIfDue() async {
        guard let client else { return }
        let recurring = settings.recurring
        guard !recurring.isEmpty else { return }

        let now = Date()
        let off = settings.tzOffsetMinutes
        let (today, weekday, year) = RecurringLogger.localDay(now: now, tzOffsetMinutes: off)

        // Weekly days off (configurable; default Sat+Sun).
        if settings.weeklyOff.contains(weekday) { return }
        // User-added + religious + (if region=morocco) fixed civil holidays.
        if RecurringLogger.allDaysOff(year: year, settings: settings).contains(today) { return }

        var ledger = RecurringLogger.loadLedger()
        var anyLogged = false
        for entry in recurring {
            guard entry.taskId != 0, entry.hours > 0 else { continue }
            let key = "\(today)|\(entry.taskId)"
            if ledger.contains(key) { continue }
            do {
                _ = try await client.logTime(entityId: entry.taskId, hours: entry.hours,
                                             description: entry.label, date: now, tzOffsetMinutes: off)
                ledger.insert(key)
                RecurringLogger.saveLedger(ledger)
                anyLogged = true
                let title = entry.label.isEmpty ? "#\(entry.taskId)" : "“\(entry.label)”"
                status = "Auto-logged \(fmt(entry.hours)) \(title)"
            } catch {
                status = "Recurring log failed: \(msg(error))"
            }
        }
        if anyLogged { await refresh() }
    }

    func billableHours(_ raw: Double) -> Double {
        let step = Double(max(1, settings.meetingStepMinutes)) / 60
        let minH = Double(max(0, settings.meetingMinMinutes)) / 60
        return max(minH, (raw / step).rounded(.up) * step)
    }

    func openInTP(_ id: Int) {
        let base = settings.tpURL.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if let url = URL(string: "\(base)/entity/\(id)") { NSWorkspace.shared.open(url) }
    }

    // MARK: helpers
    func fmt(_ h: Double) -> String { String(format: "%.2fh", (h * 100).rounded() / 100) }
    private func msg(_ e: Error) -> String { (e as? TPError)?.message ?? e.localizedDescription }
    private func isoDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }
}
