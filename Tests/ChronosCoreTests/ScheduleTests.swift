import ChronosCore
import Foundation
import Testing

/// Weekdays as `Calendar` numbers them.
private let weekdays: Set<Int> = [2, 3, 4, 5, 6]
private let work = Schedule.Label(name: "Work", color: .blue, hours: [.init(days: weekdays, start: 540, end: 1020)])
private let partTime = Schedule.Label(
    name: "Part-time",
    color: .orange,
    hours: [.init(days: [2, 3, 5], start: 1080, end: 1200)]
)

struct ScheduleTests {
    @Test func labelsThatDontTouchHaveNoConflicts() {
        #expect(Schedule(labels: [work, partTime]).conflicts == [])
    }

    @Test func hoursThatEndWhereOthersStartDontConflict() {
        let evening = Schedule.Label(name: "Evening", color: .green, hours: [.init(days: [2], start: 1020, end: 1080)])

        #expect(Schedule(labels: [work, evening]).conflicts == [])
    }

    @Test func overlappingLabelsConflictOnTheFirstSharedStretch() {
        let late = Schedule.Label(name: "Late", color: .red, hours: [.init(days: [3, 4], start: 960, end: 1140)])

        let conflicts = Schedule(labels: [work, late]).conflicts

        // Tuesday, 2 days after Sunday's midnight, from 16:00 to 17:00 is the first stretch both cover.
        let tuesday = 2 * 1440
        let overlap: Range<Int> = (tuesday + 960)..<(tuesday + 1020)
        #expect(conflicts == [Schedule.Conflict(first: "Work", second: "Late", overlap: overlap)])
    }

    @Test func hoursPastMidnightConflictWithTheNextMorning() {
        let night = Schedule.Label(name: "Night", color: .purple, hours: [.init(days: [1], start: 1320, end: 600)])

        // Sunday 22:00 runs to Monday 10:00, an hour into Monday's work.
        let monday = 1440
        let overlap: Range<Int> = (monday + 540)..<(monday + 600)
        #expect(Schedule(labels: [work, night]).conflicts.map(\.overlap) == [overlap])
    }

    @Test func saturdayNightWrapsIntoSunday() {
        let night = Schedule.Label(name: "Night", color: .purple, hours: [.init(days: [7], start: 1380, end: 60)])
        let early = Schedule.Label(name: "Early", color: .teal, hours: [.init(days: [1], start: 0, end: 30)])

        #expect(Schedule(labels: [night, early]).conflicts.map(\.overlap) == [0..<30])
    }

    @Test func aLabelCantOverlapItself() {
        let twice = Schedule.Label(
            name: "Work",
            color: .blue,
            hours: [.init(days: [2], start: 540, end: 720), .init(days: [2], start: 660, end: 780)]
        )

        #expect(Schedule(labels: [twice]).conflicts.count == 1)
    }

    @Test(arguments: [(540, 1020, 480), (1320, 120, 240), (0, 0, 1440), (600, 600, 1440)])
    func hoursLength(start: Int, end: Int, minutes: Int) {
        #expect(Schedule.Hours(days: [2], start: start, end: end).length == minutes)
    }

    @Test func windowsCoverTheDayOnceInOrder() {
        // Monday 2026-10-19.
        let windows = Schedule(labels: [work, partTime])
            .windows(from: at(2026, 10, 19), to: at(2026, 10, 20), calendar: newYork)

        #expect(
            windows == [
                .init(label: nil, start: at(2026, 10, 19), end: at(2026, 10, 19, 9)),
                .init(label: work.id, start: at(2026, 10, 19, 9), end: at(2026, 10, 19, 17)),
                .init(label: nil, start: at(2026, 10, 19, 17), end: at(2026, 10, 19, 18)),
                .init(label: partTime.id, start: at(2026, 10, 19, 18), end: at(2026, 10, 19, 20)),
                .init(label: nil, start: at(2026, 10, 19, 20), end: at(2026, 10, 20)),
            ]
        )
    }

    @Test func aDayOffIsAllUnscheduled() {
        // Sunday 2026-10-18.
        let windows = Schedule(labels: [work]).windows(from: at(2026, 10, 18), to: at(2026, 10, 19), calendar: newYork)

        #expect(windows == [.init(label: nil, start: at(2026, 10, 18), end: at(2026, 10, 19))])
    }

    @Test func hoursFromTheNightBeforeReachIntoTheDay() {
        let night = Schedule.Label(name: "Night", color: .purple, hours: [.init(days: [1], start: 1320, end: 120)])

        let windows = Schedule(labels: [night]).windows(from: at(2026, 10, 19), to: at(2026, 10, 20), calendar: newYork)

        #expect(windows.first == .init(label: night.id, start: at(2026, 10, 19), end: at(2026, 10, 19, 2)))
    }

    @Test func wallClockHoursOnADayTheClocksGoBack() {
        // 2026-11-01 is 25 hours long in New York; work on Sunday is still 9 to 5 by the clock.
        let sunday = Schedule.Label(name: "Work", color: .blue, hours: [.init(days: [1], start: 540, end: 1020)])

        let windows = Schedule(labels: [sunday]).windows(from: at(2026, 11, 1), to: at(2026, 11, 2), calendar: newYork)

        #expect(windows[1] == .init(label: sunday.id, start: at(2026, 11, 1, 9), end: at(2026, 11, 1, 17)))
        #expect(windows.reduce(0) { $0 + $1.end - $1.start } == 25 * 3600)
    }

    @Test func savesAndLoadsAndRefusesConflicts() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-\(UUID()).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(try Schedule.load(from: path) == Schedule())
        try Schedule(labels: [work, partTime]).save(to: path)
        #expect(try Schedule.load(from: path) == Schedule(labels: [work, partTime]))
        #expect(throws: Schedule.ConflictError.self) { try Schedule(labels: [work, work]).save(to: path) }
    }

    @Test func reportsTimeByLabelCuttingSlotsAtTheEdges() throws {
        let store = try Store()
        // Chrome from 16:30 to 18:30 crosses the end of work, unscheduled time, and the start of part-time.
        try store.open(slack, at: at(2026, 10, 19, 8, 30))
        try store.closeOpen(at: at(2026, 10, 19, 16, 30))
        try store.open(chrome, at: at(2026, 10, 19, 16, 30))
        try store.closeOpen(at: at(2026, 10, 19, 18, 30))
        try store.open(xcode, at: at(2026, 10, 19, 18, 30))
        let now = at(2026, 10, 19, 19)

        let windows = Schedule(labels: [work, partTime])
            .windows(from: at(2026, 10, 19), to: at(2026, 10, 20), calendar: newYork)
        let byLabel = try Report.apps(store.database, windows: windows, now: now)

        let seconds = byLabel.mapValues { $0.map { [$0.name: $0.seconds] } }
        #expect(seconds[work.id] == [["Slack": 27000], ["Google Chrome": 1800]])
        #expect(seconds[nil] == [["Google Chrome": 3600], ["Slack": 1800]])
        #expect(seconds[partTime.id] == [["Google Chrome": 1800], ["Xcode": 1800]])
        // Chrome was switched to once, during work.
        #expect(byLabel[work.id]?.first { $0.name == "Google Chrome" }?.switches == 1)
        #expect(byLabel[partTime.id]?.first { $0.name == "Google Chrome" }?.switches == 0)
        // Every label together is the whole day.
        let whole = try Report.apps(store.database, from: at(2026, 10, 19), to: at(2026, 10, 20), now: now)
        #expect(byLabel.values.joined().reduce(0) { $0 + $1.seconds } == whole.reduce(0) { $0 + $1.seconds })
    }
}
