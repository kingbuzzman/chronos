import ChronosCore
import Foundation
import os

private let log = Logger(subsystem: BundleID.recorder, category: "firefox")

/// The recorder's side of chronos-ff, the Firefox extension: the domain it last reported, and asking it for the
/// current one. See `FirefoxChannel`.
@MainActor final class FirefoxLink {
    /// What `probe` heard back.
    struct Probe {
        /// The host answered the ping.
        var helperAnswered = false
        /// The extension reported a domain.
        var extensionAnswered = false
        /// Messages from the extension the host threw away, per its answer.
        var rejected = 0
    }

    /// The domain of Firefox's tab in front, as last reported; nil until the extension answers. '' when the tab has
    /// none, such as a new tab.
    private(set) var domain: String?
    /// When the extension last reported a domain, whether or not Firefox was in front; nil if never.
    private(set) var lastReport: Date?
    /// A report came in.
    var onReport: () -> Void = {}
    private var lastPong: (at: Date, rejected: Int)?
    private var observers: [any NSObjectProtocol] = []

    init() {
        let center = DistributedNotificationCenter.default()
        observers.append(
            center.addObserver(forName: FirefoxChannel.domainReported, object: nil, queue: .main) { [weak self] note in
                let domain = note.userInfo?["domain"] as? String ?? ""
                MainActor.assumeIsolated { self?.reported(domain) }
            }
        )
        observers.append(
            center.addObserver(forName: FirefoxChannel.pong, object: nil, queue: .main) { [weak self] note in
                let rejected = note.userInfo?["rejected"] as? Int ?? 0
                MainActor.assumeIsolated { self?.lastPong = (Date(), rejected) }
            }
        )
    }

    /// Forgets the last report and asks the extension for the current domain. Its answer arrives as a report; until
    /// then, `domain` is nil, so nothing stale is ever used. If nobody answers, it stays nil.
    func ask() {
        domain = nil
        postAsk()
    }

    /// Pings the host and asks the extension for its domain, without forgetting the last one, then waits up to
    /// `timeout` for both to answer. Asking separately from pinging lets an older host, which doesn't know pings,
    /// still prove the extension works.
    func probe(timeout: Duration) async -> Probe {
        let sent = Date()
        DistributedNotificationCenter.default().postNotificationName(
            FirefoxChannel.ping,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        postAsk()
        let deadline = ContinuousClock.now + timeout
        var probe = Probe()
        while true {
            if let pong = lastPong, pong.at >= sent {
                probe.helperAnswered = true
                probe.rejected = pong.rejected
            }
            probe.extensionAnswered = lastReport.map { $0 >= sent } ?? false
            if probe.helperAnswered && probe.extensionAnswered || ContinuousClock.now >= deadline { return probe }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func postAsk() {
        log.debug("Asking chronos-ff for the domain")
        DistributedNotificationCenter.default().postNotificationName(
            FirefoxChannel.ask,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func reported(_ domain: String) {
        // Only ever a domain: anything longer isn't one.
        guard domain.count <= FirefoxChannel.longestDomain else { return }
        log.debug("chronos-ff reported \(domain, privacy: .private)")
        self.domain = domain
        lastReport = Date()
        onReport()
    }
}
