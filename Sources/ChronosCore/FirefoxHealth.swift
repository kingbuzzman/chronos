import Foundation

/// The file that tells Firefox where chronos-ff's host is, and whether what it says can work. `make ff-register` writes
/// it.
package enum FirefoxRegistration: Equatable, Sendable {
    /// Firefox can start the host at this path.
    case ok(helper: String)
    /// No file: Firefox doesn't know the host exists.
    case missing
    /// The file isn't one Firefox will use for chronos-ff; why, as a phrase.
    case invalid(String)
    /// It points at a host that isn't there or can't run, such as one inside a Chronos.app since moved or deleted.
    case helperMissing(String)

    /// `~/Library/Application Support/Mozilla/NativeMessagingHosts/com.kingbuzzman.chronos.json`.
    package static var path: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Mozilla/NativeMessagingHosts/\(FirefoxChannel.host).json"
            )
            .path
    }

    package static func check(at path: String = path) -> FirefoxRegistration {
        let files = FileManager.default
        guard files.fileExists(atPath: path) else { return .missing }
        guard let data = files.contents(atPath: path) else { return .invalid("it can't be read") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid("it isn't JSON")
        }
        guard object["name"] as? String == FirefoxChannel.host else {
            return .invalid("its name isn't \(FirefoxChannel.host)")
        }
        guard object["type"] as? String == "stdio" else { return .invalid("its type isn't stdio") }
        guard (object["allowed_extensions"] as? [String])?.contains(FirefoxChannel.extensionID) == true else {
            return .invalid("it doesn't allow \(FirefoxChannel.extensionID)")
        }
        guard let helper = object["path"] as? String, !helper.isEmpty else { return .invalid("it names no host") }
        guard files.isExecutableFile(atPath: helper) else { return .helperMissing(helper) }
        return .ok(helper: helper)
    }
}

/// What a check of the way from chronos-ff to the recorder found: each link, and the first one broken, if any.
package struct FirefoxHealth: Equatable, Sendable {
    package enum Problem: Equatable, Sendable {
        case notRegistered
        case registrationBroken(String)
        case helperMissing(String)
        /// Firefox isn't running the host: the extension isn't installed, is disabled, or can't start it.
        case notConnected
        /// The host is running, so the extension is connected, but no domain came back.
        case notAnswering(rejected: Int)
    }

    package var firefoxRunning: Bool
    package var registration: FirefoxRegistration
    /// The host answered the ping.
    package var helperAnswered: Bool
    /// The extension reported a domain after being asked.
    package var extensionAnswered: Bool
    /// Messages from the extension the host threw away as not a domain, since it started.
    package var rejected: Int
    /// When the recorder last got a domain from the extension, in unix seconds; nil if never since it started.
    package var lastReport: Int?

    package init(
        firefoxRunning: Bool,
        registration: FirefoxRegistration,
        helperAnswered: Bool = false,
        extensionAnswered: Bool = false,
        rejected: Int = 0,
        lastReport: Int? = nil
    ) {
        self.firefoxRunning = firefoxRunning
        self.registration = registration
        self.helperAnswered = helperAnswered
        self.extensionAnswered = extensionAnswered
        self.rejected = rejected
        self.lastReport = lastReport
    }

    /// Nil while domains arrive, whatever else looks off: the extension answering is the proof that matters. With
    /// Firefox closed, only a broken registration counts, since nothing can be asked.
    package var problem: Problem? {
        if firefoxRunning, extensionAnswered { return nil }
        if let problem = registrationProblem { return problem }
        guard firefoxRunning else { return nil }
        return helperAnswered ? .notAnswering(rejected: rejected) : .notConnected
    }

    private var registrationProblem: Problem? {
        switch registration {
        case .ok: nil
        case .missing: .notRegistered
        case .invalid(let why): .registrationBroken(why)
        case .helperMissing(let path): .helperMissing(path)
        }
    }

    /// What's wrong and what to do about it, for a notification.
    package static func describe(_ problem: Problem) -> String {
        switch problem {
        case .notRegistered:
            "Firefox doesn't know where Chronos's helper is. Run make ff-register."
        case .registrationBroken(let why):
            "Firefox's registration of Chronos's helper won't work: \(why). Run make ff-register again."
        case .helperMissing(let path):
            "Firefox is registered to start a helper that isn't there: \(path). Run make ff-register again."
        case .notConnected:
            "chronos-ff isn't connected. Check it's installed and enabled in Firefox: a temporary add-on is gone "
                + "after Firefox restarts."
        case .notAnswering(let rejected):
            "chronos-ff is connected but didn't say which site you're on"
                + (rejected > 0 ? ", and the helper threw away \(rejected) of its messages" : "")
                + ". Its toolbar button shows what it last sent."
        }
    }

    /// One line per link, for Settings' "Check Connection".
    package func lines(now: Int) -> [String] {
        var lines: [String] = []
        if case .ok(let helper) = registration {
            lines.append("✓ Registered with Firefox: \(helper)")
        } else if let registrationProblem {
            lines.append("✗ " + Self.describe(registrationProblem))
        }
        guard firefoxRunning else {
            lines.append("– Firefox isn't running, so chronos-ff can't be asked. Open it and check again.")
            return lines
        }
        switch (helperAnswered, extensionAnswered) {
        case (true, true):
            lines.append("✓ chronos-ff is connected and answered with the site in front")
        case (true, false):
            lines.append("✗ chronos-ff is connected, but didn't answer with the site in front")
        case (false, true):
            // The site came through the helper, so it's running: one from before the last build, which Firefox keeps
            // until chronos-ff reconnects, and too old to answer the check.
            lines.append("✓ chronos-ff is connected and answered with the site in front")
            lines.append("⚠︎ Its helper is an older version. Reload chronos-ff in Firefox to update it.")
        case (false, false):
            lines.append("✗ chronos-ff isn't connected: its helper didn't answer")
        }
        if rejected > 0 { lines.append("⚠︎ The helper threw away \(rejected) messages from chronos-ff") }
        // When chronos-ff didn't answer just now, how long it's been quiet.
        guard !extensionAnswered else { return lines }
        if let lastReport {
            lines.append("Last site from chronos-ff: \(formatDuration(max(now - lastReport, 0))) ago")
        } else {
            lines.append("No site from chronos-ff since Chronos started")
        }
        return lines
    }
}
