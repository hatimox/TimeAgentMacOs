import SwiftUI
import AppKit

/// Menu-bar (LSUIElement) app. Built programmatically so it runs as an SPM
/// executable without an Xcode project; the run.sh wrapper sets activation
/// policy to accessory so there's no Dock icon.
@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar style, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    let store = AppStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var tasksWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var recurringTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self
        buildStatusItem()
        buildPopover()
        NotificationCenter.default.addObserver(self, selector: #selector(meetingChanged),
                                               name: .meetingStateChanged, object: nil)
        Task { await store.startup() }
        if !store.settings.isConfigured { openSettings() }

        // Re-check recurring hourly, in case the app launched before midnight or
        // on a day off (matches the Electron app's hourly re-check).
        recurringTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.store.logRecurringIfDue() }
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "TimeAgent")
            btn.image?.isTemplate = true
            btn.action = #selector(togglePopover)
            btn.target = self
        }
    }

    private func buildPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(watcher: store.watcher).environmentObject(store))
    }

    @objc private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }

    @objc private func meetingChanged() {
        guard let btn = statusItem.button else { return }
        let inMeeting = store.watcher.inMeeting
        btn.image = NSImage(systemSymbolName: inMeeting ? "clock.badge.fill" : "clock",
                            accessibilityDescription: "TimeAgent")
        btn.image?.isTemplate = !inMeeting
    }

    func openTasks() {
        if tasksWindow == nil {
            let w = makeWindow(title: "TimeAgent — Tasks",
                               view: TaskListView().environmentObject(store), size: NSSize(width: 760, height: 560))
            tasksWindow = w
        }
        show(tasksWindow)
    }

    func openSettings() {
        if settingsWindow == nil {
            let w = makeWindow(title: "TimeAgent Settings",
                               view: SettingsView().environmentObject(store), size: NSSize(width: 480, height: 460))
            settingsWindow = w
        }
        show(settingsWindow)
    }

    private func makeWindow<V: View>(title: String, view: V, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.contentViewController = NSHostingController(rootView: view)
        w.center()
        w.isReleasedWhenClosed = false
        return w
    }

    private func show(_ w: NSWindow?) {
        guard let w else { return }
        popover.performClose(nil)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
