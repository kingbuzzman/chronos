import AppKit
import ChronosCore
import Foundation
import Observation
import ServiceManagement
import SwiftUI

/// Whether Chronos opens at login, as the recorder last said. The recorder owns it; see `LoginChannel`.
@MainActor @Observable final class LoginStore {
    /// Nil until the recorder answers.
    private(set) var status: LoginStatus?
    /// Why turning it on or off just failed.
    private(set) var error: String?
    /// The recorder didn't answer: it isn't running, so it can't be changed.
    private(set) var unreachable = false
    @ObservationIgnored private var answers: (any NSObjectProtocol)?
    @ObservationIgnored private var waiting: Task<Void, Never>?

    init() {
        answers = DistributedNotificationCenter.default().addObserver(
            forName: LoginChannel.status,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let status = (notification.userInfo?[LoginChannel.statusKey] as? String).flatMap(LoginStatus.init)
            let error = notification.userInfo?[LoginChannel.errorKey] as? String
            MainActor.assumeIsolated { self?.answered(status, error: error) }
        }
    }

    var isOn: Bool { status == .on || status == .needsApproval }

    func ask() {
        request(LoginChannel.ask, userInfo: nil)
    }

    func set(_ enabled: Bool) {
        request(LoginChannel.set, userInfo: [LoginChannel.enabledKey: enabled])
    }

    /// Sends a request, and gives the recorder two seconds to answer before saying it isn't running.
    private func request(_ name: Notification.Name, userInfo: [AnyHashable: Any]?) {
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.unreachable = true
        }
    }

    private func answered(_ status: LoginStatus?, error: String?) {
        waiting?.cancel()
        unreachable = false
        self.status = status
        self.error = error
    }
}

/// Settings' check of the way from chronos-ff to the recorder, which runs it. See `FirefoxCheckChannel`.
@MainActor @Observable final class FirefoxCheckStore {
    enum State: Equatable {
        case idle, checking
        case done(passed: Bool, lines: [String])
        /// The recorder didn't answer: it isn't running, so nothing can be checked.
        case unreachable
    }

    private(set) var state = State.idle
    @ObservationIgnored private var answers: (any NSObjectProtocol)?
    @ObservationIgnored private var waiting: Task<Void, Never>?

    /// Firefox, its Developer Edition or Nightly is installed; otherwise there's nothing to check.
    var firefoxIsInstalled: Bool {
        FirefoxChannel.bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    init() {
        answers = DistributedNotificationCenter.default().addObserver(
            forName: FirefoxCheckChannel.result,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let passed = notification.userInfo?[FirefoxCheckChannel.passedKey] as? Bool ?? false
            let lines = notification.userInfo?[FirefoxCheckChannel.linesKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.answered(passed: passed, lines: lines) }
        }
    }

    /// Asks the recorder to check. The helper and the extension get 5 seconds to answer, so the recorder gets 10.
    func check() {
        state = .checking
        DistributedNotificationCenter.default().postNotificationName(
            FirefoxCheckChannel.run,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.state = .unreachable
        }
    }

    private func answered(passed: Bool, lines: [String]) {
        // Only answers to this window's question: the recorder's hourly checks don't send any.
        guard state == .checking else { return }
        waiting?.cancel()
        state = .done(passed: passed, lines: lines)
    }
}

/// Settings for Chronos as a whole: whether it opens at login, and checking Firefox's connection.
struct GeneralSettings: View {
    let login: LoginStore
    let firefox: FirefoxCheckStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Like System Settings: the label on the left, a switch on the right.
            HStack {
                Text("Open Chronos at login")
                Spacer()
                Toggle(
                    "Open Chronos at login",
                    isOn: Binding(get: { login.isOn }, set: { login.set($0) })
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(login.status == nil)
            }

            Text("Chronos only records while it's running. Opened at login, it's in the menu bar from the start.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if login.unreachable {
                Notice(symbol: "exclamationmark.triangle.fill", color: .orange) {
                    Text("Chronos isn't running in the menu bar, so this can't be changed.")
                }
            } else if let error = login.error {
                Notice(symbol: "xmark.octagon.fill", color: .red) { Text(error) }
            } else if login.status == .needsApproval {
                Notice(symbol: "exclamationmark.triangle.fill", color: .orange) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            "Chronos is turned off under Login Items in System Settings. Allow it there to open at login."
                        )
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(.link)
                    }
                }
            }

            if firefox.firefoxIsInstalled {
                Divider().padding(.vertical, 4)
                FirefoxCheckSection(firefox: firefox)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: login.ask)
    }
}

/// Checks that Firefox's sites reach Chronos, and shows how each link did.
private struct FirefoxCheckSection: View {
    let firefox: FirefoxCheckStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Firefox connection")
                Spacer()
                if firefox.state == .checking {
                    ProgressView().controlSize(.small)
                }
                Button("Check Connection", action: firefox.check)
                    .disabled(firefox.state == .checking)
            }

            Text(
                "Checks every step from chronos-ff, the Firefox extension, to Chronos. Chronos also checks once an hour "
                    + "while Firefox is open, and sends a notification if something's wrong."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            switch firefox.state {
            case .idle, .checking:
                EmptyView()
            case .unreachable:
                Notice(symbol: "exclamationmark.triangle.fill", color: .orange) {
                    Text("Chronos isn't running in the menu bar, so it can't be checked.")
                }
            case .done(let passed, let lines):
                VStack(alignment: .leading, spacing: 6) {
                    if passed {
                        Notice(symbol: "checkmark.circle.fill", color: .green) {
                            Text("Firefox's sites are reaching Chronos.")
                        }
                    } else {
                        Notice(symbol: "xmark.octagon.fill", color: .red) {
                            Text("Firefox's sites aren't reaching Chronos.")
                        }
                    }
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
