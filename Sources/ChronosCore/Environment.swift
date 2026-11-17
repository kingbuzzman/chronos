package import Foundation

package enum BundleID {
    package static let recorder = "com.kingbuzzman.chronos"
    package static let viewer = "com.kingbuzzman.chronos.viewer"
}

/// Recorder → viewer: the menu's items that open a part of the viewer.
package enum ViewerChannel {
    /// Show Settings. A viewer that isn't running yet gets `settingsArgument` at launch instead: it would miss this.
    package static let showSettings = Notification.Name("com.kingbuzzman.chronos.viewer.settings")
    package static let settingsArgument = "--settings"
}

/// Viewer → recorder: the schedule was saved, so the recorder looks at its allowances again.
package enum ScheduleChannel {
    package static let saved = Notification.Name("com.kingbuzzman.chronos.schedule.saved")
}

/// Viewer ↔ recorder: whether Chronos opens at login. The recorder is what opens, and only an app can register itself
/// as a login item, so it owns the setting; the viewer's Settings ask for it and change it. Every request is answered
/// with a `status`, and a recorder that isn't running answers nothing.
package enum LoginChannel {
    /// Viewer → recorder: "is it on?"
    package static let ask = Notification.Name("com.kingbuzzman.chronos.login.ask")
    /// Viewer → recorder: turn it on or off, as `userInfo[enabledKey]`, a Bool.
    package static let set = Notification.Name("com.kingbuzzman.chronos.login.set")
    /// Recorder → viewer: a `LoginStatus` raw value in `userInfo[statusKey]`, and if turning it on or off just failed,
    /// why, in `userInfo[errorKey]`.
    package static let status = Notification.Name("com.kingbuzzman.chronos.login.status")
    package static let enabledKey = "enabled"
    package static let statusKey = "status"
    package static let errorKey = "error"
}

package enum LoginStatus: String, Sendable {
    case on, off
    /// Registered, but turned off under System Settings → General → Login Items until allowed there.
    case needsApproval
}

package enum Paths {
    /// `~/Library/Application Support/Chronos`.
    package static var folder: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Chronos")
            .path
    }

    /// `chronos.sqlite` in `folder`, or `CHRONOS_DATABASE` if set, for trying things out without touching the real one.
    package static var database: String {
        if let path = ProcessInfo.processInfo.environment["CHRONOS_DATABASE"], !path.isEmpty { return path }
        return folder + "/chronos.sqlite"
    }

    /// The `Schedule`, next to the database, so trying things out against another database doesn't touch the real
    /// labels either. The viewer writes it; the recorder only reads its allowances.
    package static var schedule: String {
        URL(fileURLWithPath: database).deletingLastPathComponent().appendingPathComponent("schedule.json").path
    }

    /// The recorder's `InstanceLock`. Always in `folder`, whatever the database: one recorder per user, even when
    /// trying things out against another database.
    package static var lock: String { folder + "/chronos.lock" }
}

/// Wall-clock time that advances with a monotonic clock between anchors, so a clock correction during a slot can't
/// stretch or shrink it. Re-anchored whenever recording resumes and when the system clock is changed.
package final class WallClock {
    private var wall = Date().timeIntervalSince1970
    private var instant = ContinuousClock.now

    package init() {}

    package func reanchor() {
        wall = Date().timeIntervalSince1970
        instant = ContinuousClock.now
    }

    /// Unix seconds.
    package func now() -> Double {
        let elapsed = (ContinuousClock.now - instant).components
        return wall + Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}
