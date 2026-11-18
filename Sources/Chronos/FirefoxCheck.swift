import AppKit
import ChronosCore
import UserNotifications
import os

private let log = Logger(subsystem: BundleID.recorder, category: "firefox")

/// Checks that chronos-ff's domains still reach Chronos, and sends a notification when they don't: once an hour while
/// Firefox is running, and on demand from Settings (`FirefoxCheckChannel`). Firefox closed, it doesn't wake at all.
@MainActor final class FirefoxCheck {
    static let interval: Duration = .seconds(60 * 60)
    /// The first check after Firefox starts waits this long: the extension connects as Firefox starts, and otherwise
    /// retries every 30 seconds.
    static let firstCheck: Duration = .seconds(2 * 60)
    /// How long the host and the extension get to answer.
    static let timeout: Duration = .seconds(5)
    /// Each notice replaces the last one in Notification Center rather than piling up next to it.
    private static let noticeID = "firefox-check"

    static var firefoxIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && FirefoxChannel.bundleIDs.contains($0.bundleIdentifier ?? "")
        }
    }

    private let link: FirefoxLink
    private var hourly: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    /// What the last check found wrong, for the menu's warning; nil if nothing, or not checked since Firefox started.
    private(set) var problem: FirefoxHealth.Problem?

    init(link: FirefoxLink) {
        self.link = link
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard FirefoxChannel.bundleIDs.contains(app?.bundleIdentifier ?? "") else { return }
                    MainActor.assumeIsolated { self?.firefoxChanged() }
                }
            )
        }
        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: FirefoxCheckChannel.run,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkForSettings() }
            }
        )
        firefoxChanged()
    }

    /// Checks every link from chronos-ff to here, and notes what's wrong for the menu's warning. Doesn't notify: whoever
    /// asked sees the result.
    func check() async -> FirefoxHealth {
        var health = FirefoxHealth(
            firefoxRunning: Self.firefoxIsRunning,
            registration: FirefoxRegistration.check(),
            lastReport: link.lastReport.map { Int($0.timeIntervalSince1970) }
        )
        if health.firefoxRunning {
            let probe = await link.probe(timeout: Self.timeout)
            health.helperAnswered = probe.helperAnswered
            health.extensionAnswered = probe.extensionAnswered
            health.rejected = probe.rejected
        }
        problem = health.problem
        let lines = health.lines(now: Int(Date().timeIntervalSince1970)).joined(separator: "; ")
        if problem == nil {
            log.notice("Firefox check passed: \(lines, privacy: .public)")
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.noticeID])
        } else {
            log.error("Firefox check failed: \(lines, privacy: .public)")
        }
        return health
    }

    /// Settings asked: checks, and sends them how each link did.
    private func checkForSettings() {
        Task {
            let health = await check()
            DistributedNotificationCenter.default().postNotificationName(
                FirefoxCheckChannel.result,
                object: nil,
                userInfo: [
                    FirefoxCheckChannel.passedKey: health.problem == nil,
                    FirefoxCheckChannel.linesKey: health.lines(now: Int(Date().timeIntervalSince1970)),
                ],
                deliverImmediately: true
            )
        }
    }

    private func firefoxChanged() {
        guard Self.firefoxIsRunning else {
            hourly?.cancel()
            hourly = nil
            problem = nil
            return
        }
        guard hourly == nil else { return }
        hourly = Task { [weak self] in
            var delay = Self.firstCheck
            while true {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                delay = Self.interval
                // Never set up for Firefox (no make ff-register): nothing to check, and nothing to nag about.
                guard FirefoxRegistration.check() != .missing else {
                    problem = nil
                    continue
                }
                if let problem = await check().problem { notify(problem) }
            }
        }
    }

    private func notify(_ problem: FirefoxHealth.Problem) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Chronos isn't getting sites from Firefox"
        content.body = FirefoxHealth.describe(problem)
        let request = UNNotificationRequest(identifier: Self.noticeID, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                // Asks only the first time; after that, says what was answered.
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    log.error("Notifications aren't allowed, so the Firefox check can't say what it found")
                    return
                }
                try await center.add(request)
            } catch {
                log.error("Couldn't notify about Firefox: \(error, privacy: .public)")
            }
        }
    }
}
