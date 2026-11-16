import AppKit
import ChronosCore
import Foundation
import Observation
import SwiftUI

/// The schedule as saved, which reports use, and as being edited in Settings, which is saved as soon as no two
/// labels overlap. Until then the report keeps using the last saved one.
@MainActor @Observable final class ScheduleStore {
    var draft: Schedule {
        didSet { save() }
    }
    private(set) var saved: Schedule
    private(set) var error: String?

    init() {
        var schedule = Schedule()
        do {
            schedule = try Schedule.load(from: Paths.schedule)
        } catch {
            self.error = "Couldn't read \(Paths.schedule): \(error). Labels will replace it once you change them."
        }
        saved = schedule
        draft = schedule
    }

    func addLabel() {
        let used = Set(draft.labels.map(\.color))
        let color = Schedule.Tint.allCases.first { !used.contains($0) } ?? .graphite
        // No days yet, so it can't overlap anything until it's given some.
        draft.labels.append(
            Schedule.Label(name: "", color: color, hours: [Schedule.Hours(days: [], start: 9 * 60, end: 17 * 60)])
        )
    }

    func remove(_ label: Schedule.Label) {
        draft.labels.removeAll { $0.id == label.id }
    }

    private func save() {
        guard draft != saved, draft.conflicts.isEmpty else { return }
        do {
            try draft.save(to: Paths.schedule)
            saved = draft
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}

/// The Settings window, one tab per pane, in the toolbar like other Mac apps' settings.
@MainActor final class SettingsWindow {
    enum Pane: Int {
        case schedule, about
    }

    private let window: NSWindow
    private let tabs = NSTabViewController()

    init(schedule: ScheduleStore) {
        tabs.tabStyle = .toolbar
        for (title, symbol, view) in [
            ("Schedule", "calendar", AnyView(ScheduleSettings(store: schedule))),
            ("About", "info.circle", AnyView(AboutView())),
        ] {
            let content = NSHostingController(rootView: view.frame(width: 560, height: 480))
            // The window takes each pane's size, and its title from the pane on screen.
            content.preferredContentSize = NSSize(width: 560, height: 480)
            content.title = title
            let item = NSTabViewItem(viewController: content)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show(_ pane: Pane) {
        tabs.selectedTabViewItemIndex = pane.rawValue
        window.makeKeyAndOrderFront(nil)
    }
}

extension Schedule.Tint {
    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .graphite: .gray
        }
    }
}

extension Schedule.Label {
    /// What the viewer calls it: its name, or a stand-in while it has none.
    var title: String {
        let name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }
}
