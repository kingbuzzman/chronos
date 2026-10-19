/// Turns focus changes into slots. A new focus is written only once it has lasted `settle` seconds, so passing
/// through apps with Cmd-Tab never touches the disk; coming back to the open slot within that time leaves it
/// untouched. When the new focus is written, the old slot is closed, and the new one opened, at the moment focus left
/// the old one, so the timeline has no gaps.
package final class Tracker {
    package static let settle: Double = 1

    private let store: Store
    private let now: () -> Double
    /// What the open slot in the database is for.
    package private(set) var current: Target?
    private var pending: (target: Target, since: Double)?
    /// When focus left `current`, while `pending` settles.
    private var leftAt: Double?

    /// `now` is unix seconds.
    package init(store: Store, now: @escaping () -> Double) {
        self.store = store
        self.now = now
    }

    /// Whether a focus is waiting for `commit()`, which the caller schedules `settle` seconds after `focus(_:)`.
    package var isPending: Bool { pending != nil }

    package func focus(_ target: Target) {
        if target == current {
            pending = nil
            leftAt = nil
            return
        }
        if target == pending?.target { return }
        let time = now()
        if current != nil, leftAt == nil { leftAt = time }
        pending = (target, time)
    }

    /// Writes the pending focus: closes the open slot and opens the new one, in one transaction.
    package func commit() throws {
        guard let pending else { return }
        let start = Int((leftAt ?? pending.since).rounded())
        try store.database.transaction {
            if current != nil { try store.closeOpen(at: start) }
            try store.open(pending.target, at: start)
        }
        current = pending.target
        self.pending = nil
        leftAt = nil
    }

    /// Closes the open slot: the Mac is going to sleep, locking, or Chronos is quitting. A pending focus that has
    /// already settled is written first, in case its scheduled commit hasn't run yet.
    package func stop() throws {
        let time = now()
        if let pending, time - pending.since >= Self.settle { try commit() }
        pending = nil
        if current != nil { try store.closeOpen(at: Int((leftAt ?? time).rounded())) }
        current = nil
        leftAt = nil
    }
}
