import AppKit
import ApplicationServices
import ChronosCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var recorder: Recorder?
    private var statusMenu: StatusMenu?
    private var allowances: AllowanceWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let path = Paths.database
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let store = try Store(path: path)
            // Whatever the last run left open, its crash handler couldn't close.
            try store.recover()
            try CrashClose.prepare(path: path)
            installCrashHandlers()
            // Asks for Accessibility the first time; without it, Chronos records apps but not browser tabs.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

            let recorder = Recorder(store: store)
            let allowances = AllowanceWatcher(database: store.database)
            recorder.recorded = { allowances.focusChanged($0) }
            recorder.start()
            self.recorder = recorder
            self.allowances = allowances
            statusMenu = StatusMenu(recorder: recorder, allowances: allowances)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Chronos can't open its database"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    /// Quit from the menu, logout and shutdown all come through here.
    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
        for viewer in NSRunningApplication.runningApplications(withBundleIdentifier: BundleID.viewer) {
            viewer.terminate()
        }
    }
}
