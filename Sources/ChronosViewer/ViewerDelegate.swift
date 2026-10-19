import AppKit
import SwiftUI

/// A regular app with a window and a Dock icon. Closing the window quits it; the recorder in the menu bar keeps
/// running.
@MainActor final class ViewerDelegate: NSObject, NSApplicationDelegate {
    private let model = ReportModel()
    private var window: NSWindow?
    private var refreshing: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        let content = NSHostingController(rootView: ReportView(model: model))
        // Let the window be resized freely, rather than held to the view's ideal size.
        content.sizingOptions = []
        let window = NSWindow(contentViewController: content)
        window.title = "Chronos"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 420, height: 520))
        window.contentMinSize = NSSize(width: 360, height: 440)
        // Opens where it was last closed; centered the first time.
        if !window.setFrameUsingName("Viewer") { window.center() }
        window.setFrameAutosaveName("Viewer")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Fresh numbers as soon as you come back to it, then every 10 seconds while it's in front, so the open slot's
    /// time keeps counting. Nothing runs while you're elsewhere.
    func applicationDidBecomeActive(_ notification: Notification) {
        model.load()
        refreshing?.cancel()
        refreshing = Task { [model] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                model.load()
            }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        refreshing?.cancel()
        refreshing = nil
    }

    /// Without a main menu, Cmd-Q and Cmd-W do nothing.
    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Hide Chronos", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for submenu in [app, file, window] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        NSApp.windowsMenu = window
        return menu
    }
}
