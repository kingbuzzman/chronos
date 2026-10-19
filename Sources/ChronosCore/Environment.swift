import Foundation

package enum BundleID {
    package static let recorder = "com.kingbuzzman.chronos"
    package static let viewer = "com.kingbuzzman.chronos.viewer"
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
