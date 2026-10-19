import ChronosCore
import Testing

struct StoreTests {
    @Test func opensAndClosesASlot() throws {
        let store = try Store()

        try store.open(chrome, at: at(2026, 10, 19, 9))
        #expect(
            try store.slots == [
                SlotRow(
                    bundleID: chrome.bundleID,
                    domain: "github.com",
                    program: nil,
                    start: at(2026, 10, 19, 9),
                    end: nil,
                    duration: nil,
                    continued: false
                )
            ]
        )

        try store.closeOpen(at: at(2026, 10, 19, 9, 30))
        #expect(try store.slots.map(\.duration) == [1800])
    }

    @Test func aProgramIsAnAppOfItsOwnThatTheSlotPointsAt() throws {
        let store = try Store()

        try store.open(claude, at: at(2026, 10, 19, 9))

        let slots = try store.slots
        #expect(slots.map(\.bundleID) == ["com.apple.Terminal"])
        #expect(slots.map(\.program) == ["claude"])
        #expect(slots.map(\.domain) == [""])
        #expect(
            try store.database.rows("SELECT bundle_id, kind FROM apps ORDER BY id") { [$0.text(0), $0.text(1)] }
                == [["com.apple.Terminal", "app"], ["claude", "program"]]
        )
    }

    @Test func aSlotCantHaveBothADomainAndAProgram() throws {
        let store = try Store()
        let both = Target(bundleID: "com.apple.Terminal", name: "Terminal", domain: "github.com", program: "claude")

        #expect(throws: StoreError.self) { try store.open(both, at: at(2026, 10, 19, 9)) }
        #expect(try store.slots == [])
    }

    @Test func theMidnightSplitKeepsTheProgram() throws {
        let store = try Store()
        try store.open(claude, at: at(2026, 10, 19, 23))

        try store.closeOpen(at: at(2026, 10, 20, 1))

        #expect(try store.slots.map(\.program) == ["claude", "claude"])
    }

    @Test func onlyOneSlotCanBeOpen() throws {
        let store = try Store()
        try store.open(chrome, at: at(2026, 10, 19, 9))

        #expect(throws: SQLiteError.self) { try store.open(slack, at: at(2026, 10, 19, 9, 5)) }
    }

    @Test func closingWithNothingOpenDoesNothing() throws {
        let store = try Store()

        try store.closeOpen(at: at(2026, 10, 19, 9))
        #expect(try store.slots == [])
    }

    @Test func splitsAtMidnight() throws {
        let store = try Store()
        try store.open(slack, at: at(2026, 10, 19, 22))

        try store.closeOpen(at: at(2026, 10, 20, 0, 10))

        let slots = try store.slots
        #expect(slots.map(\.start) == [at(2026, 10, 19, 22), at(2026, 10, 20)])
        #expect(slots.map(\.end) == [at(2026, 10, 20), at(2026, 10, 20, 0, 10)])
        #expect(slots.map(\.duration) == [2 * 3600, 600])
        #expect(slots.map(\.continued) == [false, true])
        #expect(slots.allSatisfy { $0.bundleID == slack.bundleID })
    }

    @Test func splitsASlotSpanningSeveralDays() throws {
        let store = try Store()
        try store.open(xcode, at: at(2026, 10, 19, 23))

        try store.closeOpen(at: at(2026, 10, 22, 1))

        let slots = try store.slots
        #expect(slots.map(\.duration) == [3600, 86_400, 86_400, 3600])
        #expect(slots.map(\.continued) == [false, true, true, true])
    }

    @Test func recoveryGivesAnOpenSlotOneSecond() throws {
        let store = try Store()
        try store.open(chrome, at: at(2026, 10, 19, 9))

        try store.recover()

        #expect(try store.slots.map(\.duration) == [1])
    }

    @Test func keepsTheLatestAppName() throws {
        let store = try Store()
        try store.open(slack, at: at(2026, 10, 19, 9))
        try store.closeOpen(at: at(2026, 10, 19, 10))

        try store.open(Target(bundleID: slack.bundleID, name: "Slack Beta"), at: at(2026, 10, 19, 10))

        #expect(try store.database.rows("SELECT name FROM apps") { $0.text(0) } == ["Slack Beta"])
    }
}
