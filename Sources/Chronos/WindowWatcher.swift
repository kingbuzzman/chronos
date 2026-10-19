import ApplicationServices

/// Watches the frontmost app's windows through Accessibility: a new focused window, or a title change, which is how
/// a browser's tab switch shows up. Needs the Accessibility permission; without it, watching quietly does nothing.
@MainActor final class WindowWatcher {
    enum Change {
        /// Another window came forward.
        case window
        /// A window's title changed: a new tab or page, or a new program in Terminal, or just a page updating it.
        case title
        /// Focus moved inside the window, such as to another Terminal tab. Only reported with `followFocus`.
        case focus
    }

    /// Accessibility callbacks are C functions that can't capture anything, so they find the watcher here.
    private static weak var shared: WindowWatcher?

    var onChange: (Change) -> Void = { _ in }
    private var observer: AXObserver?
    private var watchedPID: pid_t?

    init() {
        Self.shared = self
    }

    /// Moves the watch to this app. Retries an app it couldn't watch before, such as before Accessibility was granted.
    /// `followFocus` also reports focus moving inside a window, which is how Terminal shows a tab switch.
    func watch(_ pid: pid_t, followFocus: Bool) {
        guard pid != watchedPID else { return }
        unwatch()
        var created: AXObserver?
        let status = AXObserverCreate(
            pid,
            { _, element, notification, _ in
                let change: Change
                switch notification as String {
                case kAXTitleChangedNotification:
                    // Titles change on buttons, tabs and text too; only a window's title is a page or document
                    // changing.
                    guard role(of: element) == kAXWindowRole else { return }
                    change = .title
                case kAXFocusedUIElementChangedNotification: change = .focus
                default: change = .window
                }
                MainActor.assumeIsolated { WindowWatcher.shared?.onChange(change) }
            },
            &created
        )
        guard status == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        var watching = false
        let notifications =
            [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXTitleChangedNotification]
            + (followFocus ? [kAXFocusedUIElementChangedNotification] : [])
        for notification in notifications
        where AXObserverAddNotification(observer, app, notification as CFString, nil) == .success {
            watching = true
        }
        guard watching else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        watchedPID = pid
    }

    /// Stops watching: for apps whose windows don't matter, so their title changes don't wake Chronos at all.
    func unwatch() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        watchedPID = nil
    }
}

private func role(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
    return value as? String
}
