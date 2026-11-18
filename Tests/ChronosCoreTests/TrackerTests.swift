import ChronosCore
import Testing

struct TrackerTests {
    let store: Store
    let clock = FakeClock(at(2026, 10, 19, 9))
    let input = FakeInput()
    let tracker: Tracker

    init() throws {
        store = try Store()
        tracker = Tracker(store: store, now: { [clock] in clock.time }, input: { [input] in input.counts })
    }

    @Test func nothingIsWrittenUntilFocusSettles() throws {
        tracker.focus(chrome)

        #expect(tracker.isPending)
        #expect(try store.slots == [])

        clock.advance(1)
        try tracker.commit()
        #expect(try store.slots.map(\.start) == [at(2026, 10, 19, 9)])
        #expect(tracker.current == chrome)
    }

    @Test func switchingClosesAndOpensAtTheSameInstant() throws {
        try settle(on: chrome)
        clock.advance(600)

        tracker.focus(slack)
        clock.advance(1)
        try tracker.commit()

        let slots = try store.slots
        #expect(slots.map(\.bundleID) == [chrome.bundleID, slack.bundleID])
        #expect(slots[0].end == slots[1].start)
        #expect(slots[0].duration == 601)
    }

    @Test func passingThroughAppsWritesNothing() throws {
        try settle(on: chrome)
        clock.advance(600)

        tracker.focus(slack)
        clock.advance(0.3)
        tracker.focus(xcode)
        clock.advance(0.3)
        tracker.focus(chrome)

        #expect(!tracker.isPending)
        #expect(try store.slots.count == 1)
        #expect(try store.slots[0].end == nil)
    }

    @Test func blipsCountTowardTheSlotThatSettles() throws {
        try settle(on: chrome)
        clock.advance(600)
        let left = clock.time

        tracker.focus(slack)
        clock.advance(0.4)
        tracker.focus(xcode)
        clock.advance(1)
        try tracker.commit()

        let slots = try store.slots
        #expect(slots.map(\.bundleID) == [chrome.bundleID, xcode.bundleID])
        #expect(slots[1].start == Int(left))
    }

    @Test func refocusingThePendingTargetKeepsItsStart() throws {
        tracker.focus(chrome)
        clock.advance(0.5)
        tracker.focus(chrome)
        clock.advance(0.5)
        try tracker.commit()

        #expect(try store.slots.map(\.start) == [at(2026, 10, 19, 9)])
    }

    @Test func aNewDomainIsANewSlot() throws {
        try settle(on: chrome)
        clock.advance(60)

        tracker.focus(Target(bundleID: chrome.bundleID, name: chrome.name, domain: "docs.google.com"))
        clock.advance(1)
        try tracker.commit()

        #expect(try store.slots.map(\.domain) == ["github.com", "docs.google.com"])
    }

    @Test func aNewProgramIsANewSlot() throws {
        try settle(on: claude)
        clock.advance(60)

        tracker.focus(Target(bundleID: claude.bundleID, name: claude.name, program: "zsh"))
        clock.advance(1)
        try tracker.commit()

        #expect(try store.slots.map(\.program) == ["claude", "zsh"])
    }

    @Test func stopClosesTheOpenSlot() throws {
        try settle(on: chrome)
        clock.advance(300)

        try tracker.stop()

        #expect(try store.slots.map(\.duration) == [301])
        #expect(tracker.current == nil)
    }

    @Test func stopDropsAnUnsettledFocusAndEndsWhenFocusLeft() throws {
        try settle(on: chrome)
        clock.advance(300)
        tracker.focus(slack)
        clock.advance(0.5)

        try tracker.stop()

        let slots = try store.slots
        #expect(slots.map(\.bundleID) == [chrome.bundleID])
        #expect(slots[0].duration == 301)
    }

    @Test func stopWritesASettledFocusWhoseCommitHasNotRun() throws {
        try settle(on: chrome)
        clock.advance(300)
        tracker.focus(slack)
        clock.advance(5)

        try tracker.stop()

        let slots = try store.slots
        #expect(slots.map(\.bundleID) == [chrome.bundleID, slack.bundleID])
        #expect(slots.map(\.duration) == [301, 5])
    }

    @Test func focusAfterStopStartsAfresh() throws {
        try settle(on: chrome)
        try tracker.stop()
        clock.advance(3600)

        try settle(on: chrome)

        let slots = try store.slots
        #expect(slots.count == 2)
        #expect(slots[1].start == Int(clock.time) - 1)
    }

    @Test func inputGoesToWhatWasInFrontInEachChunk() throws {
        try settle(on: chrome)
        input.type(10)
        input.click(2)
        clock.advance(119)

        tracker.focus(slack)
        // Typed while Slack settles: Slack's, since focus had already left Chrome.
        input.type(2)
        clock.advance(1)
        try tracker.commit()
        input.type(3)
        clock.advance(180)
        try tracker.tick()

        #expect(
            try store.input == [
                InputRow(at(2026, 10, 19, 9), chrome, keys: 10, clicks: 2),
                InputRow(at(2026, 10, 19, 9), slack, keys: 5),
            ]
        )
    }

    @Test func eachChunkIsWrittenAtTheTickAfterIt() throws {
        try settle(on: chrome)
        input.type(4)
        clock.advance(299)

        try tracker.tick()
        #expect(try store.input == [InputRow(at(2026, 10, 19, 9), chrome, keys: 4)])

        input.type(6)
        clock.advance(300)
        try tracker.tick()
        #expect(
            try store.input == [
                InputRow(at(2026, 10, 19, 9), chrome, keys: 4),
                InputRow(at(2026, 10, 19, 9, 5), chrome, keys: 6),
            ]
        )
    }

    @Test func aChunkWithoutInputWritesNothing() throws {
        try settle(on: chrome)
        clock.advance(299)
        try tracker.tick()
        clock.advance(300)
        try tracker.tick()

        #expect(try store.input == [])
    }

    @Test func aTickWhileAFocusSettlesCreditsOnlyUntilFocusLeft() throws {
        try settle(on: chrome)
        input.type(1)
        clock.advance(298.5)
        tracker.focus(slack)
        input.type(2)
        clock.advance(0.7)

        try tracker.tick()
        clock.advance(0.5)
        try tracker.commit()
        try tracker.stop()

        #expect(
            try store.input == [
                InputRow(at(2026, 10, 19, 9), chrome, keys: 1),
                InputRow(at(2026, 10, 19, 9, 5), slack, keys: 2),
            ]
        )
    }

    @Test func stopWritesTheChunkSoFar() throws {
        try settle(on: chrome)
        input.type(7)
        clock.advance(60)

        try tracker.stop()

        #expect(try store.input == [InputRow(at(2026, 10, 19, 9), chrome, keys: 7)])
    }

    @Test func inputWhileStoppedIsNobodys() throws {
        try settle(on: chrome)
        try tracker.stop()
        input.type(50)
        clock.advance(3600)

        try settle(on: chrome)
        input.type(1)
        try tracker.stop()

        #expect(try store.input == [InputRow(at(2026, 10, 19, 10), chrome, keys: 1)])
    }

    @Test func theCountersWrapping() {
        let before = InputCounts(keys: UInt32.max - 1)
        let after = InputCounts(keys: 3)

        #expect(after.since(before).keys == 5)
    }

    private func settle(on target: Target) throws {
        tracker.focus(target)
        clock.advance(1)
        try tracker.commit()
    }
}
