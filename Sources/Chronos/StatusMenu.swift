import AppKit
import ApplicationServices
import ChronosCore

/// The menu bar icon and its menu. The totals are read when the menu opens; nothing updates in the background.
@MainActor final class StatusMenu: NSObject, NSMenuDelegate {
    private let recorder: Recorder
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init()
        // A template image: macOS tints it for light and dark menu bars.
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            Logo.drawWatch(in: context, rect: rect, color: CGColor(gray: 0, alpha: 1))
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = "Chronos"
        item.button?.image = icon
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let apps = recorder.today()
        let today = apps.reduce(0) { $0 + $1.seconds }
        menu.addItem(info("Today: \(formatDuration(today))", hover: formatDurationPrecisely(today)))
        if let top = apps.first {
            menu.addItem(
                info("Top: \(top.name) — \(formatDuration(top.seconds))", hover: formatDurationPrecisely(top.seconds))
            )
        }
        if !AXIsProcessTrusted() {
            menu.addItem(info("⚠︎ Accessibility not allowed: sites and Terminal programs aren't recorded"))
        }
        for app in recorder.details.denied.sorted() {
            menu.addItem(info("⚠︎ Automation not allowed for \(app): only its app time is recorded"))
        }
        menu.addItem(.separator())
        menu.addItem(action("Open Viewer", #selector(openViewer)))
        menu.addItem(action("Quit", #selector(quit), key: "q"))
    }

    /// Opens the viewer, or brings its window forward if it's already open.
    @objc private func openViewer() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Chronos.app")
        let configuration = NSWorkspace.OpenConfiguration()
        // Apps opened this way don't inherit the environment, so pass on a database other than the real one.
        if let database = ProcessInfo.processInfo.environment["CHRONOS_DATABASE"] {
            configuration.environment = ["CHRONOS_DATABASE": database]
        }
        // Since macOS 14, an app only comes to the front if the app in front agrees.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: BundleID.viewer)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func info(_ title: String, hover: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = hover
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }
}
