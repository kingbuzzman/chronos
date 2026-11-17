import ChronosCore
import Foundation
import ServiceManagement
import os

private let log = Logger(subsystem: BundleID.recorder, category: "login")

/// Opening Chronos at login, for the viewer's Settings. See `LoginChannel`. The recorder registers itself, the app
/// that's running, as a login item: a build run from elsewhere registers that build.
@MainActor final class LoginItem {
    private var requests: [any NSObjectProtocol] = []

    init() {
        let center = DistributedNotificationCenter.default()
        requests.append(
            center.addObserver(forName: LoginChannel.ask, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.answer() }
            }
        )
        requests.append(
            center.addObserver(forName: LoginChannel.set, object: nil, queue: .main) { [weak self] notification in
                let enabled = notification.userInfo?[LoginChannel.enabledKey] as? Bool
                MainActor.assumeIsolated {
                    guard let enabled else { return }
                    self?.set(enabled)
                }
            }
        )
    }

    private var status: LoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    private func set(_ enabled: Bool) {
        var failure: String?
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Couldn't turn \(enabled ? "on" : "off") opening at login: \(error)")
            failure = error.localizedDescription
        }
        answer(failure: failure)
    }

    private func answer(failure: String? = nil) {
        var info: [String: String] = [LoginChannel.statusKey: status.rawValue]
        info[LoginChannel.errorKey] = failure
        DistributedNotificationCenter.default().postNotificationName(
            LoginChannel.status,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }
}
