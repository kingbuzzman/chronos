import AppKit
import ChronosCore
import Foundation
import Observation
import SwiftUI

/// The schedule as saved, which reports and the recorder's allowances use, and as being edited in Settings, which is
/// saved as soon as no two labels overlap. Until then both keep using the last saved one.
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

    /// Deletes the label, and the allowances that count only during it: they'd never count again.
    func remove(_ label: Schedule.Label) {
        var schedule = draft
        schedule.labels.removeAll { $0.id == label.id }
        schedule.allowances.removeAll { $0.during == .label(label.id) }
        draft = schedule
    }

    func addAllowance(for subject: Allowance.Subject) {
        draft.allowances.append(Allowance(subject: subject, amount: 30, unit: .minutes, per: .day))
    }

    func remove(_ allowance: Allowance) {
        draft.allowances.removeAll { $0.id == allowance.id }
    }

    private func save() {
        guard draft != saved, draft.conflicts.isEmpty else { return }
        do {
            try draft.save(to: Paths.schedule)
            saved = draft
            error = nil
            // The recorder reads the allowances again.
            DistributedNotificationCenter.default().postNotificationName(
                ScheduleChannel.saved,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        } catch {
            self.error = "\(error)"
        }
    }
}

/// The Settings window, one tab per pane, in the toolbar like other Mac apps' settings.
@MainActor final class SettingsWindow {
    enum Pane: Int {
        case general, schedule, allowances, about
    }

    private let window: NSWindow
    private let tabs = NSTabViewController()
    private let login = LoginStore()
    private let firefox = FirefoxCheckStore()

    init(schedule: ScheduleStore) {
        tabs.tabStyle = .toolbar
        for (title, symbol, view) in [
            ("General", "gearshape", AnyView(GeneralSettings(login: login, firefox: firefox))),
            ("Schedule", "calendar", AnyView(ScheduleSettings(store: schedule))),
            ("Allowances", "hourglass", AnyView(AllowanceSettings(store: schedule))),
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
        // Asked for from the menu bar, the viewer may be behind other apps.
        NSApp.activate()
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
