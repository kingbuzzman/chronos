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

/// Settings for Chronos as a whole: for now, whether it opens at login.
struct GeneralSettings: View {
    let login: LoginStore

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

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: login.ask)
    }
}
