import ChronosCore
import Foundation

/// The recorder's side of chronos-ff, the Firefox extension: the domain it last reported, and asking it for the
/// current one. See `FirefoxChannel`.
@MainActor final class FirefoxLink {
    /// The domain of Firefox's tab in front, as last reported; nil until the extension answers. '' when the tab has
    /// none, such as a new tab.
    private(set) var domain: String?
    /// A report came in.
    var onReport: () -> Void = {}
    private var reports: (any NSObjectProtocol)?

    init() {
        reports = DistributedNotificationCenter.default().addObserver(
            forName: FirefoxChannel.domainReported,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let domain = notification.userInfo?["domain"] as? String ?? ""
            MainActor.assumeIsolated { self?.reported(domain) }
        }
    }

    /// Forgets the last report and asks the extension for the current domain. Its answer arrives as a report; until
    /// then, `domain` is nil, so nothing stale is ever used. If nobody answers, it stays nil.
    func ask() {
        domain = nil
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
        self.domain = domain
        onReport()
    }
}
