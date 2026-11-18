/// Turns focus changes into slots. A new focus is written only once it has lasted `settle` seconds, so passing
/// through apps with Cmd-Tab never touches the disk; coming back to the open slot within that time leaves it
/// untouched. When the new focus is written, the old slot is closed, and the new one opened, at the moment focus left
/// the old one, so the timeline has no gaps.
///
/// It also credits input to whatever's in front, for `InputLog`: from a reading when focus leaves each target, and one
/// at each chunk boundary (`tick()`).
package final class Tracker {
    package static let settle: Double = 1

    private let store: Store
    private let now: () -> Double
    private let input: () -> InputCounts
    private let log: InputLog
    /// The input reading up to which input has been credited; nil while no slot is open.
    private var counted: InputCounts?
    /// What the open slot in the database is for.
    package private(set) var current: Target?
    private var pending: (target: Target, since: Double)?
    /// When focus left `current`, while `pending` settles, and the input reading then.
    private var left: (at: Double, input: InputCounts)?

    /// `now` is unix seconds. `input` reads macOS's running input totals.
    package init(store: Store, now: @escaping () -> Double, input: @escaping () -> InputCounts = { InputCounts() }) {
        self.store = store
        self.now = now
        self.input = input
        log = InputLog(store: store)
    }

    /// Whether a focus is waiting for `commit()`, which the caller schedules `settle` seconds after `focus(_:)`.
    package var isPending: Bool { pending != nil }

    package func focus(_ target: Target) {
        if target == current {
            pending = nil
            left = nil
            return
        }
        if target == pending?.target { return }
        let time = now()
        if current != nil, left == nil { left = (time, input()) }
        pending = (target, time)
    }

    /// Writes the pending focus: closes the open slot and opens the new one, in one transaction.
    package func commit() throws {
        guard let pending else { return }
        let start = Int((left?.at ?? pending.since).rounded())
        let reading = left?.input ?? input()
        let previous = current
        try store.database.transaction {
            if current != nil { try store.closeOpen(at: start) }
            try store.open(pending.target, at: start)
        }
        current = pending.target
        self.pending = nil
        left = nil
        // The input until focus left was the old target's. After the slots, so failing to write it can't hold them up.
        try credit(upTo: reading, to: previous)
    }

    /// A chunk boundary passed: the input since the last reading goes to what's in front, and the chunk that ended is
    /// written. While a new focus settles, only the input until focus left: the rest is the new focus's.
    package func tick() throws {
        guard let current else { return }
        try credit(upTo: left?.input ?? input(), to: current)
    }

    /// Closes the open slot: the Mac is going to sleep, locking, or Chronos is quitting. A pending focus that has
    /// already settled is written first, in case its scheduled commit hasn't run yet. Then writes the input counted so
    /// far.
    package func stop() throws {
        let time = now()
        if let pending, time - pending.since >= Self.settle { try commit() }
        pending = nil
        guard let current else { return }
        let reading = left?.input ?? input()
        try store.closeOpen(at: Int((left?.at ?? time).rounded()))
        self.current = nil
        left = nil
        defer { counted = nil }
        try credit(upTo: reading, to: current)
        try log.write()
    }

    /// Credits the input since the last reading to `target`, or to nothing if no slot was open.
    private func credit(upTo reading: InputCounts, to target: Target?) throws {
        defer { counted = reading }
        if let target, let counted {
            try log.add(reading.since(counted), to: target, at: now())
        } else {
            log.begin(at: now())
        }
    }
}
