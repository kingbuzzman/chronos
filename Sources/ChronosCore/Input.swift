/// Input totals: how many keys, clicks, scrolls and mouse moves, never which key or where. macOS keeps running totals
/// since login; Chronos reads them when focus moves and at each `InputLog.chunk` boundary, and never sees the events
/// themselves.
package struct InputCounts: Equatable, Sendable {
    package var keys: UInt32
    package var clicks: UInt32
    package var scrolls: UInt32
    package var moves: UInt32

    package init(keys: UInt32 = 0, clicks: UInt32 = 0, scrolls: UInt32 = 0, moves: UInt32 = 0) {
        self.keys = keys
        self.clicks = clicks
        self.scrolls = scrolls
        self.moves = moves
    }

    package var isEmpty: Bool { self == InputCounts() }

    /// What came in between an earlier reading and this one. The totals are 32-bit and wrap, so this wraps too.
    package func since(_ earlier: InputCounts) -> InputCounts {
        InputCounts(
            keys: keys &- earlier.keys,
            clicks: clicks &- earlier.clicks,
            scrolls: scrolls &- earlier.scrolls,
            moves: moves &- earlier.moves
        )
    }

    static func + (left: InputCounts, right: InputCounts) -> InputCounts {
        InputCounts(
            keys: left.keys &+ right.keys,
            clicks: left.clicks &+ right.clicks,
            scrolls: left.scrolls &+ right.scrolls,
            moves: left.moves &+ right.moves
        )
    }
}

/// Input per 5-minute chunk of the clock, per target in front, kept in memory until the chunk ends and then written in
/// one transaction, a row per target that had any. A chunk without input writes nothing.
package final class InputLog {
    /// Seconds per chunk. Chunks start on multiples of it, in unix time, which are on the local clock's 5-minute marks in
    /// every time zone, since all of them are whole quarter hours off UTC.
    package static let chunk = 300

    /// How late the chunk boundary's reading may be, in seconds, so macOS can fold it into a wake-up it was making
    /// anyway. Input in that lateness counts toward the chunk before. Longer in Low Power Mode.
    package static func slack(lowPower: Bool) -> Double { lowPower ? 60 : 10 }

    /// The start of the chunk `time` is in.
    package static func chunk(containing time: Double) -> Int {
        Int((time / Double(chunk)).rounded(.down)) * chunk
    }

    /// Seconds from `time` to the start of the next chunk.
    package static func untilNextChunk(after time: Double) -> Double {
        Double(chunk(containing: time) + chunk) - time
    }

    private let store: Store
    /// The chunk being counted, and what each target had in it so far.
    private var current: (start: Int, totals: [(target: Target, input: InputCounts)])?

    package init(store: Store) {
        self.store = store
    }

    /// Starts counting the chunk `time` is in, unless one is being counted already.
    package func begin(at time: Double) {
        if current == nil { current = (Self.chunk(containing: time), []) }
    }

    /// Adds input to the target, in the chunk being counted; at `time`, if that's in a later chunk, writes the counted
    /// one and starts counting that one. Input is added first: it came in before `time`, mostly in the chunk that's
    /// ending.
    package func add(_ input: InputCounts, to target: Target, at time: Double) throws {
        let start = Self.chunk(containing: time)
        var chunk = current ?? (start, [])
        if !input.isEmpty {
            if let index = chunk.totals.firstIndex(where: { $0.target == target }) {
                chunk.totals[index].input = chunk.totals[index].input + input
            } else {
                chunk.totals.append((target, input))
            }
        }
        current = chunk
        if start != chunk.start { try write() }
        if current == nil { current = (start, []) }
    }

    /// Writes the chunk being counted, as far as it got: recording is stopping.
    package func write() throws {
        guard let chunk = current else { return }
        current = nil
        guard !chunk.totals.isEmpty else { return }
        try store.database.transaction {
            for (target, input) in chunk.totals { try store.addInput(input, to: target, inChunkAt: chunk.start) }
        }
    }
}
