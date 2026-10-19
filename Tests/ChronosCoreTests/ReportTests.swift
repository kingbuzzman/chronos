import ChronosCore
import Foundation
import Testing

struct ReportTests {
    @Test func totalsPerAppMostFirst() throws {
        let store = try Store()
        try record(store, chrome, from: at(2026, 10, 19, 9), to: at(2026, 10, 19, 10))
        try record(store, slack, from: at(2026, 10, 19, 10), to: at(2026, 10, 19, 10, 30))
        try record(store, chrome, from: at(2026, 10, 19, 10, 30), to: at(2026, 10, 19, 11))

        let totals = try Report.apps(
            store.database,
            from: at(2026, 10, 19),
            to: at(2026, 10, 20),
            now: at(2026, 10, 20)
        )

        #expect(
            totals == [
                AppTotal(
                    bundleID: chrome.bundleID,
                    name: chrome.name,
                    seconds: 5400,
                    switches: 2,
                    parts: [AppTotal.Part(name: "github.com", kind: .site, seconds: 5400)]
                ),
                AppTotal(bundleID: slack.bundleID, name: slack.name, seconds: 1800, switches: 1),
            ]
        )
    }

    @Test func breaksAnAppDownByWhatRanInsideIt() throws {
        let store = try Store()
        let terminal = { (program: String?) in
            Target(bundleID: "com.apple.Terminal", name: "Terminal", program: program)
        }
        try record(store, terminal("claude"), from: at(2026, 10, 19, 9), to: at(2026, 10, 19, 9, 30))
        try record(store, terminal("zsh"), from: at(2026, 10, 19, 9, 30), to: at(2026, 10, 19, 9, 40))
        try record(store, terminal(nil), from: at(2026, 10, 19, 9, 40), to: at(2026, 10, 19, 9, 45))
        try record(store, terminal("claude"), from: at(2026, 10, 19, 9, 45), to: at(2026, 10, 19, 10))
        try record(store, slack, from: at(2026, 10, 19, 10), to: at(2026, 10, 19, 10, 5))

        let totals = try Report.apps(
            store.database,
            from: at(2026, 10, 19),
            to: at(2026, 10, 20),
            now: at(2026, 10, 20)
        )

        #expect(totals.map(\.name) == ["Terminal", "Slack"])
        #expect(totals[0].seconds == 3600)
        #expect(totals[0].switches == 4)
        #expect(
            totals[0].parts == [
                AppTotal.Part(name: "claude", kind: .program, seconds: 2700),
                AppTotal.Part(name: "zsh", kind: .program, seconds: 600),
                AppTotal.Part(name: "", kind: .unidentified, seconds: 300),
            ]
        )
        #expect(totals[1].parts == [])
    }

    @Test func unidentifiedTimeComesLastHoweverBig() throws {
        let store = try Store()
        let terminal = { (program: String?) in
            Target(bundleID: "com.apple.Terminal", name: "Terminal", program: program)
        }
        try record(store, terminal(nil), from: at(2026, 10, 19, 9), to: at(2026, 10, 19, 10))
        try record(store, terminal("claude"), from: at(2026, 10, 19, 10), to: at(2026, 10, 19, 10, 5))

        let totals = try Report.apps(
            store.database,
            from: at(2026, 10, 19),
            to: at(2026, 10, 20),
            now: at(2026, 10, 20)
        )

        #expect(totals[0].parts.map(\.kind) == [.program, .unidentified])
    }

    @Test func anAppWithOnlyUnidentifiedTimeHasNoParts() throws {
        let store = try Store()
        try record(
            store,
            Target(bundleID: chrome.bundleID, name: chrome.name),
            from: at(2026, 10, 19, 9),
            to: at(2026, 10, 19, 10)
        )

        let totals = try Report.apps(
            store.database,
            from: at(2026, 10, 19),
            to: at(2026, 10, 20),
            now: at(2026, 10, 20)
        )

        #expect(totals.map(\.parts) == [[]])
    }

    @Test func includesTheOpenSlotUpToNow() throws {
        let store = try Store()
        try store.open(xcode, at: at(2026, 10, 19, 14))

        let totals = try Report.apps(
            store.database,
            from: at(2026, 10, 19),
            to: at(2026, 10, 20),
            now: at(2026, 10, 19, 14, 20)
        )

        #expect(totals.map(\.seconds) == [1200])
    }

    @Test func clipsAnOpenSlotFromYesterdayToToday() throws {
        let store = try Store()
        try store.open(xcode, at: at(2026, 10, 19, 23))
        let now = at(2026, 10, 20, 0, 30)

        let yesterday = try Report.apps(store.database, from: at(2026, 10, 19), to: at(2026, 10, 20), now: now)
        let today = try Report.apps(store.database, from: at(2026, 10, 20), to: at(2026, 10, 21), now: now)

        #expect(yesterday.map(\.seconds) == [3600])
        #expect(today.map(\.seconds) == [1800])
        #expect(today.map(\.switches) == [0])
    }

    @Test func aCarryOverIsNotASwitch() throws {
        let store = try Store()
        try record(store, slack, from: at(2026, 10, 19, 22), to: at(2026, 10, 20, 0, 10))

        let today = try Report.apps(store.database, from: at(2026, 10, 20), to: at(2026, 10, 21), now: at(2026, 10, 21))

        #expect(today == [AppTotal(bundleID: slack.bundleID, name: slack.name, seconds: 600, switches: 0)])
    }

    @Test func periodsAreLocal() {
        let date = Date(timeIntervalSince1970: TimeInterval(at(2026, 10, 19, 15)))

        func bounds(_ period: Period) -> [Int] {
            let interval = period.interval(containing: date, calendar: newYork)
            return [Int(interval.start.timeIntervalSince1970), Int(interval.end.timeIntervalSince1970)]
        }

        #expect(bounds(.day) == [at(2026, 10, 19), at(2026, 10, 20)])
        #expect(bounds(.month) == [at(2026, 10, 1), at(2026, 11, 1)])
        #expect(bounds(.year) == [at(2026, 1, 1), at(2027, 1, 1)])
    }

    @Test(arguments: [(0, "0s"), (59, "59s"), (60, "1m"), (119, "1m"), (3599, "59m"), (3600, "1h"), (24_120, "6h")])
    func durationsUseOneUnitRoundedDown(seconds: Int, text: String) {
        #expect(formatDuration(seconds) == text)
    }

    @Test(arguments: [(59, "59s"), (60, "1.00m"), (69, "1.15m"), (3599, "59.98m"), (3600, "1.00h"), (4140, "1.15h")])
    func preciseDurationsHaveTwoDecimals(seconds: Int, text: String) {
        #expect(formatDurationPrecisely(seconds) == text)
    }

    @Test func forgettingASiteKeepsItsTimeAsUnidentified() throws {
        let store = try Store()
        let site = { (domain: String) in Target(bundleID: chrome.bundleID, name: chrome.name, domain: domain) }
        let safari = Target(bundleID: "com.apple.Safari", name: "Safari", domain: "github.com")
        try record(store, site("github.com"), from: at(2026, 10, 18, 9), to: at(2026, 10, 18, 10))
        try record(store, site("example.com"), from: at(2026, 10, 19, 9), to: at(2026, 10, 19, 9, 30))
        try record(store, site("github.com"), from: at(2026, 10, 19, 9, 30), to: at(2026, 10, 19, 10))
        try record(store, safari, from: at(2026, 10, 19, 10), to: at(2026, 10, 19, 10, 10))
        try store.open(site("github.com"), at: at(2026, 10, 19, 10, 10))

        try Forget.site("github.com", in: chrome.bundleID, store.database)

        // Every day and the open slot, in that browser only.
        #expect(
            try store.slots.map(\.domain) == ["", "example.com", "", "github.com", ""]
        )
        let totals = try Report.apps(
            store.database,
            from: at(2026, 10, 19),
            to: at(2026, 10, 20),
            now: at(2026, 10, 19, 10, 20)
        )
        #expect(
            totals[0].parts == [
                AppTotal.Part(name: "example.com", kind: .site, seconds: 1800),
                AppTotal.Part(name: "", kind: .unidentified, seconds: 2400),
            ]
        )
        // The recorder can still close the slot it has open.
        try store.closeOpen(at: at(2026, 10, 19, 10, 30))
        #expect(try store.slots.last?.end == at(2026, 10, 19, 10, 30))
    }

    @Test func forgettingNeedsTheLatestSchema() throws {
        let database = try Database(path: ":memory:")
        try Schema.migrate(database, path: ":memory:", migrations: Array(Schema.migrations.prefix(2)))

        #expect(throws: Forget.OutdatedError.self) { try Forget.site("github.com", in: chrome.bundleID, database) }
    }

    private func record(_ store: Store, _ target: Target, from start: Int, to end: Int) throws {
        try store.open(target, at: start)
        try store.closeOpen(at: end)
    }
}
