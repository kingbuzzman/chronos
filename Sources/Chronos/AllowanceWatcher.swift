import ChronosCore
import Foundation
import UserNotifications
import os

private let log = Logger(subsystem: BundleID.recorder, category: "allowances")

/// Sends a notification when what's in front has used up its allowance, and every 15 minutes it stays in front after
/// that. It only reads: it never closes, blocks or slows anything, and what's recorded doesn't change.
///
/// It looks whenever focus is written, and in between sleeps until the moment an allowance would run out (or its
/// label starts, or its period starts over). With nothing that has an allowance in front, it doesn't wake at all.
@MainActor final class AllowanceWatcher {
    /// How often to remind while the subject stays in front over its allowance.
    static let reminder = 15 * 60

    private let database: Database
    private let calendar = Calendar.autoupdatingCurrent
    private var schedule = Schedule()
    /// The schedule file's modification date when last read, to read it again only once it has changed.
    private var scheduleDate: Date?
    /// What the open slot is for, or nil while not recording.
    private var focus: Target?
    /// When the last notice for each allowance went out, in unix seconds.
    private var lastNotice: [UUID: Int] = [:]
    private var wakeUp: Task<Void, Never>?
    private var saved: (any NSObjectProtocol)?
    /// Notifications are turned off for Chronos, so allowances can't say anything; for the menu's warning.
    private(set) var notificationsDenied = false

    init(database: Database) {
        self.database = database
        saved = DistributedNotificationCenter.default().addObserver(
            forName: ScheduleChannel.saved,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        reload()
    }

    var hasAllowances: Bool { !schedule.allowances.isEmpty }

    /// A slot was opened for `target`, or closed with nothing after it (nil).
    func focusChanged(_ target: Target?) {
        focus = target
        check()
    }

    /// Asks whether notifications are allowed, the first time there's an allowance, and notes if they're not.
    func refreshPermission() {
        guard hasAllowances, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            guard status == .notDetermined else {
                Task { @MainActor in self?.notificationsDenied = status == .denied }
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in self?.notificationsDenied = !granted }
            }
        }
    }

    private func check() {
        wakeUp?.cancel()
        wakeUp = nil
        reload()
        guard let focus else { return }
        let now = Date()
        let seconds = Int(now.timeIntervalSince1970)
        var next: Int?
        for allowance in schedule.allowances where allowance.subject.matches(focus) {
            do {
                let usage = try allowance.usage(database, schedule: schedule, at: now, calendar: calendar)
                let decision = usage.next(now: seconds, lastNotice: lastNotice[allowance.id], reminder: Self.reminder)
                if decision.notify {
                    lastNotice[allowance.id] = seconds
                    notify(allowance, usage)
                }
                next = min(next ?? decision.at, decision.at)
            } catch {
                let name = allowance.subject.name
                log.error("Reading \(name, privacy: .public)'s time failed: \(error, privacy: .public)")
            }
        }
        guard let next else { return }
        let delay = max(Double(next) - now.timeIntervalSince1970, 1)
        wakeUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    /// Reads the schedule again if the file changed since the last read, by the viewer or by hand.
    private func reload() {
        let path = Paths.schedule
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard date != scheduleDate else { return }
        scheduleDate = date
        do {
            schedule = try Schedule.load(from: path)
            log.notice("Read \(self.schedule.allowances.count, privacy: .public) allowances")
        } catch {
            log.error("Reading \(path, privacy: .public) failed, keeping the last one: \(error, privacy: .public)")
        }
        refreshPermission()
    }

    private func notify(_ allowance: Allowance, _ usage: Allowance.Usage) {
        let name = allowance.subject.name
        log.notice("\(name, privacy: .public) is over its allowance: \(usage.used)s of \(usage.limit)s")
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time to stop: \(name)"
        content.body =
            "You're over its allowance: \(Allowance.describe(usage.used)) of \(Allowance.describe(usage.limit)) "
            + "\(period(allowance.per))\(during(allowance.during))."
        content.sound = .default
        // A reminder replaces the allowance's last notice rather than piling up next to it.
        let request = UNNotificationRequest(identifier: allowance.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            log.error("Couldn't notify about \(name, privacy: .public): \(error, privacy: .public)")
            Task { @MainActor in self?.refreshPermission() }
        }
    }

    private func period(_ per: Allowance.Per) -> String {
        switch per {
        case .day: "today"
        case .week: "this week"
        case .month: "this month"
        }
    }

    private func during(_ during: Allowance.During?) -> String {
        switch during {
        case nil: ""
        case .unscheduled: ", outside your labels"
        case .label(let id): schedule.labels.first { $0.id == id }.map { " during \($0.name)" } ?? ""
        }
    }
}
