import ChronosCore
import Foundation

/// What's inside an app, for the apps Chronos can see into: the current tab's host in browsers, and the program in
/// front in Terminal.
///
/// Chrome-based browsers, Safari and Terminal answer through AppleScript, which asks for the Automation permission once
/// per app. Firefox has no AppleScript for URLs; chronos-ff, its extension, reports its domain instead.
@MainActor final class Details {
    private enum Kind {
        case chromium, safari, terminal
    }

    private static let kinds: [String: Kind] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.apple.Terminal": .terminal,
    ]

    /// AppleScript's error when the user said no to Automation for that app.
    private static let notPermitted = -1743

    let firefox = FirefoxLink()
    private var scripts: [String: NSAppleScript] = [:]
    /// The terminal device of Terminal's selected tab, while the focus hasn't moved. Asking Terminal takes an Apple
    /// Event; a title change alone, such as Claude Code at work, needs only a system call on the known device.
    private var terminalTTY: String?
    /// Programs' launch names by job, so each is read once rather than on every title change.
    private var programNames: [ForegroundJob.Leader: String] = [:]
    /// Names of the apps the user hasn't allowed Chronos to read, for the menu's warning.
    private(set) var denied: Set<String> = []

    /// Whether the app's details change with its window title: a new tab or page, or a new program. Not Firefox, whose
    /// extension says when its domain changes.
    func watchesTitles(_ bundleID: String) -> Bool {
        Self.kinds[bundleID] != nil
    }

    /// Whether a tab switch shows up as focus moving, rather than only as a title change.
    func followsFocus(_ bundleID: String) -> Bool {
        Self.kinds[bundleID] == .terminal
    }

    /// The focus moved, maybe to another Terminal tab: ask Terminal for its selected tab next time.
    func forgetTerminalTab() {
        terminalTTY = nil
    }

    /// What to record for the app in front: the app itself, plus its current host or the program running in it, when
    /// the app has one and will say.
    func target(bundleID: String, name: String) -> Target {
        if FirefoxChannel.bundleIDs.contains(bundleID) {
            return Target(bundleID: bundleID, name: name, domain: firefox.domain.flatMap(Host.of) ?? "")
        }
        switch Self.kinds[bundleID] {
        case .chromium:
            let url = run("URL of active tab of front window", in: bundleID, name: name)
            return Target(bundleID: bundleID, name: name, domain: url.flatMap(Host.of) ?? "")
        case .safari:
            let url = run("URL of current tab of front window", in: bundleID, name: name)
            return Target(bundleID: bundleID, name: name, domain: url.flatMap(Host.of) ?? "")
        case .terminal:
            return Target(bundleID: bundleID, name: name, program: terminalProgram(bundleID: bundleID, name: name))
        case nil:
            return Target(bundleID: bundleID, name: name)
        }
    }

    private func terminalProgram(bundleID: String, name: String) -> String? {
        if let tty = terminalTTY, let leader = ForegroundJob.leader(onTTY: tty) { return programName(of: leader) }
        // The device isn't known, or its tab has closed.
        terminalTTY = run("tty of selected tab of front window", in: bundleID, name: name)
        return terminalTTY.flatMap(ForegroundJob.leader).flatMap(programName(of:))
    }

    private func programName(of leader: ForegroundJob.Leader) -> String? {
        if let name = programNames[leader] { return name }
        guard let name = ForegroundJob.launchName(of: leader.pid) else { return nil }
        // Old jobs are gone for good; start over rather than grow.
        if programNames.count >= 100 { programNames.removeAll() }
        programNames[leader] = name
        return name
    }

    private func run(_ expression: String, in bundleID: String, name: String) -> String? {
        let script =
            scripts[bundleID]
            ?? NSAppleScript(
                source: """
                    with timeout of 1 second
                        tell application id "\(bundleID)" to return \(expression)
                    end timeout
                    """
            )
        guard let script else { return nil }
        scripts[bundleID] = script
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == Self.notPermitted { denied.insert(name) }
            return nil
        }
        denied.remove(name)
        return result.stringValue
    }
}
