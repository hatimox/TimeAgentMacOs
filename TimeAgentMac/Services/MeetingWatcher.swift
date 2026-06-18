import Foundation
import AppKit

/// Native meeting detection. Polls CoreAudio in-process (no subprocess), so the
/// Electron freezes (wedged JS timer phase, hung child processes) cannot occur.
/// A GCD timer on the main queue drives it; macOS does not throttle these the
/// way Electron throttles background renderer timers.
@MainActor
final class MeetingWatcher: ObservableObject {
    @Published private(set) var inMeeting = false
    @Published private(set) var sessionStart: Date?

    var minSeconds: Double = 60
    private let idleInterval: TimeInterval = 8
    private let activeInterval: TimeInterval = 3
    private var timer: Timer?
    private var lastSeen: Date?
    private var suppressed = false
    private var suppressedAt: Date?
    private let suppressMax: TimeInterval = 90
    private var busy = false

    /// Called when a meeting segment ends and should be logged.
    var onMeetingEnded: ((Date, Date) async -> Void)?

    func start() {
        schedule(idleInterval)
        Task { await self.poll() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    private func poll() async {
        if busy { schedule(activeInterval); return }
        let active = MicMonitor.inUse()
        let now = Date()

        if suppressed {
            let expired = suppressedAt.map { now.timeIntervalSince($0) > suppressMax } ?? true
            if !active || expired {
                suppressed = false; suppressedAt = nil
            } else {
                setState(false, nil)
                schedule(activeInterval); return
            }
        }

        if active {
            if sessionStart == nil { setState(true, now) }
            lastSeen = now
        } else if let start = sessionStart {
            let seen = lastSeen ?? start
            setState(false, nil)
            let end = now.timeIntervalSince(seen) > idleInterval * 3 ? seen : now
            if end.timeIntervalSince(start) >= minSeconds {
                busy = true
                await onMeetingEnded?(start, end)
                busy = false
            }
        }
        schedule(sessionStart != nil ? activeInterval : idleInterval)
    }

    private func setState(_ active: Bool, _ start: Date?) {
        inMeeting = active
        sessionStart = active ? (start ?? sessionStart) : nil
        updateTrayBadge()
    }

    /// Split: log the current segment now and start a fresh one (breakout rooms).
    func splitNow() async {
        guard let start = sessionStart, !busy else { return }
        let end = Date()
        setState(false, nil); lastSeen = nil
        if end.timeIntervalSince(start) >= minSeconds {
            busy = true; await onMeetingEnded?(start, end); busy = false
        }
        schedule(0.01)
    }

    /// Stop tracking the current meeting (logs elapsed) without leaving the call;
    /// suppresses re-detection until the mic goes idle or the cap expires.
    func stopTracking() async {
        guard let start = sessionStart, !busy else { return }
        let end = Date()
        setState(false, nil); lastSeen = nil
        suppressed = true; suppressedAt = end
        if end.timeIntervalSince(start) >= minSeconds {
            busy = true; await onMeetingEnded?(start, end); busy = false
        }
        schedule(activeInterval)
    }

    private func updateTrayBadge() {
        NotificationCenter.default.post(name: .meetingStateChanged, object: nil)
    }
}

extension Notification.Name {
    static let meetingStateChanged = Notification.Name("meetingStateChanged")
}
