import AppKit
import ChronosCore
import CoreGraphics
import os

private let log = Logger(subsystem: BundleID.recorder, category: "recorder")

/// Listens for focus and session changes and feeds them to the tracker. Between events it does nothing at all.
@MainActor final class Recorder {
    /// Reasons not to record. Recording happens only while there are none.
    private enum Blocker {
        case asleep, displayAsleep, locked, screensaver, switchedOut
    }

    private let store: Store
    private let clock = WallClock()
    private let tracker: Tracker
    private let windows = WindowWatcher()
    let details = Details()
    private var blockers: Set<Blocker> = []
    private var settling: Task<Void, Never>?
    private var windowChange: Task<Void, Never>?
    /// Whether a window or focus change came in since the last refresh, so Terminal's tab may be another one.
    private var tabMayHaveChanged = false
    private var observers: [any NSObjectProtocol] = []

    init(store: Store) {
        self.store = store
        tracker = Tracker(store: store, now: { [clock] in clock.now() })
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.focusChanged() }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.block(.asleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.unblock(.asleep) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.block(.displayAsleep) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.unblock(.displayAsleep) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.block(.switchedOut) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.unblock(.switchedOut) }
        // Logout or shutdown: close now. If it's cancelled, the next focus change opens a new slot.
        observe(workspace, NSWorkspace.willPowerOffNotification) { recorder in
            recorder.record { try recorder.tracker.stop() }
        }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.block(.locked) }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.unblock(.locked) }
        observe(distributed, "com.apple.screensaver.didstart") { $0.block(.screensaver) }
        observe(distributed, "com.apple.screensaver.didstop") { $0.unblock(.screensaver) }
        // Accessibility was granted or revoked. The new setting takes a moment to apply.
        observe(distributed, "com.apple.accessibility.api") { recorder in
            Task {
                try? await Task.sleep(for: .seconds(1))
                recorder.focusChanged()
            }
        }

        observe(NotificationCenter.default, .NSSystemClockDidChange) { $0.clockChanged() }

        windows.onChange = { [weak self] in self?.windowChanged($0) }
        details.firefox.onReport = { [weak self] in self?.firefoxReported() }
        if screenIsLocked() { blockers.insert(.locked) }
        focusChanged()
    }

    /// Chronos is quitting.
    func stop() {
        settling?.cancel()
        record { try tracker.stop() }
    }

    /// Time per app today, including the open slot, for the menu.
    func today() -> [AppTotal] {
        let now = Date(timeIntervalSince1970: clock.now())
        do {
            return try Report.apps(store.database, in: .day, at: now, calendar: .autoupdatingCurrent)
        } catch {
            log.error("Reading today's totals failed: \(error, privacy: .public)")
            return []
        }
    }

    /// Reads what's in front and tells the tracker; a new focus is written once it has settled. Firefox is asked for its
    /// current domain each time, unless this is its answer: its answer replaces the focus while it settles.
    /// `sameTab`: only a title changed, so Terminal's selected tab is the one already known.
    private func focusChanged(firefoxAnswered: Bool = false, sameTab: Bool = false) {
        guard blockers.isEmpty, let app = NSWorkspace.shared.frontmostApplication else { return }
        if !sameTab { details.forgetTerminalTab() }
        if !firefoxAnswered, let bundleID = app.bundleIdentifier, FirefoxChannel.bundleIDs.contains(bundleID) {
            details.firefox.ask()
        }
        // Only apps Chronos can see into are watched; every other app's window events never reach it.
        if let bundleID = app.bundleIdentifier, details.watchesTitles(bundleID) {
            windows.watch(app.processIdentifier, followFocus: details.followsFocus(bundleID))
        } else {
            windows.unwatch()
        }
        tracker.focus(target(for: app))
        settling?.cancel()
        guard tracker.isPending else { return }
        settling = Task {
            try? await Task.sleep(for: .seconds(Tracker.settle))
            guard !Task.isCancelled else { return }
            record { try tracker.commit() }
        }
    }

    /// A window or title changed in the frontmost app. Only apps with details care: it may be a new tab or page, or a
    /// new program in Terminal. Titles change in bursts (Terminal's flickers with every helper a program starts), so
    /// this waits for them to settle before asking the app.
    private func windowChanged(_ change: WindowWatcher.Change) {
        guard let app = NSWorkspace.shared.frontmostApplication,
            let bundleID = app.bundleIdentifier, details.watchesTitles(bundleID)
        else { return }
        if change != .title { tabMayHaveChanged = true }
        windowChange?.cancel()
        windowChange = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let sameTab = !tabMayHaveChanged
            tabMayHaveChanged = false
            focusChanged(sameTab: sameTab)
        }
    }

    private func target(for app: NSRunningApplication) -> Target {
        let bundleID = app.bundleIdentifier ?? app.executableURL?.path ?? "pid \(app.processIdentifier)"
        // The viewer is part of Chronos.
        if bundleID.hasPrefix(BundleID.recorder) { return Target(bundleID: BundleID.recorder, name: "Chronos") }
        let name = app.localizedName ?? bundleID
        return details.target(bundleID: bundleID, name: name)
    }

    /// chronos-ff reported a domain: a tab change it noticed, or an answer to `ask()`. Only matters while Firefox is in
    /// front; otherwise it's kept for nothing, since Firefox is asked afresh when it comes back.
    private func firefoxReported() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            FirefoxChannel.bundleIDs.contains(bundleID)
        else { return }
        focusChanged(firefoxAnswered: true)
    }

    private func block(_ blocker: Blocker) {
        let wasRecording = blockers.isEmpty
        blockers.insert(blocker)
        guard wasRecording else { return }
        settling?.cancel()
        record { try tracker.stop() }
    }

    private func unblock(_ blocker: Blocker) {
        blockers.remove(blocker)
        // Waking into a locked screen isn't a return: wait for the unlock.
        if screenIsLocked() { blockers.insert(.locked) }
        guard blockers.isEmpty else { return }
        clock.reanchor()
        focusChanged()
    }

    /// The system clock was changed: close the slot at the old time and start again at the new one.
    private func clockChanged() {
        settling?.cancel()
        record { try tracker.stop() }
        clock.reanchor()
        focusChanged()
    }

    private func record(_ write: () throws -> Void) {
        do {
            try write()
        } catch {
            log.error("Writing a slot failed: \(error, privacy: .public)")
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ action: @escaping @MainActor (Recorder) -> Void
    ) {
        observers.append(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            }
        )
    }

    private func observe(
        _ center: DistributedNotificationCenter,
        _ name: String,
        _ action: @escaping @MainActor (Recorder) -> Void
    ) {
        observe(center as NotificationCenter, Notification.Name(name), action)
    }
}

private func screenIsLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
}
