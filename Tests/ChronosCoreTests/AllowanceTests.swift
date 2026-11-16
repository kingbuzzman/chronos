import ChronosCore
import Foundation
import Testing

private let work = Schedule.Label(
    name: "Work",
    color: .blue,
    hours: [.init(days: [2, 3, 4, 5, 6], start: 540, end: 1020)]
)
private let youtube = Target(bundleID: "com.google.Chrome", name: "Google Chrome", domain: "youtube.com")
private let mobileYoutube = Target(bundleID: "com.apple.Safari", name: "Safari", domain: "m.youtube.com")

/// How much of `allowance` is used at `now`, in `schedule`.
private func usage(
    _ allowance: Allowance,
    _ store: Store,
    now: Int,
    schedule: Schedule = Schedule()
) throws -> Allowance.Usage {
    try allowance.usage(
        store.database,
        schedule: schedule,
        at: Date(timeIntervalSince1970: TimeInterval(now)),
        calendar: newYork
    )
}

/// A whole day that counts, with `used` of `limit` seconds used.
private func day(used: Int, limit: Int) -> Allowance.Usage {
    Allowance.Usage(
        start: 0,
        end: 86_400,
        windows: [.init(label: nil, start: 0, end: 86_400)],
        used: used,
        limit: limit
    )
}

struct AllowanceTests {
    @Test func aSiteIncludesItsSubdomainsButNotLookalikes() {
        let site = Allowance.Subject.site(domain: "youtube.com")

        #expect(site.matches(youtube))
        #expect(site.matches(mobileYoutube))
        #expect(!site.matches(Target(bundleID: "com.google.Chrome", name: "Chrome", domain: "notyoutube.com")))
        #expect(!site.matches(Target(bundleID: "com.google.Chrome", name: "Chrome", domain: "youtube.com.evil")))
    }

    @Test func anAppOrProgramMatchesByName() {
        #expect(Allowance.Subject.app(bundleID: slack.bundleID, name: "Slack").matches(slack))
        #expect(!Allowance.Subject.app(bundleID: slack.bundleID, name: "Slack").matches(xcode))
        #expect(Allowance.Subject.program(name: "claude").matches(claude))
        #expect(!Allowance.Subject.program(name: "vim").matches(claude))
    }

    @Test func countsASiteInEveryBrowserAndTheOpenSlot() throws {
        let store = try Store()
        try store.open(youtube, at: at(2026, 10, 19, 8))
        try store.closeOpen(at: at(2026, 10, 19, 8, 10))
        try store.open(chrome, at: at(2026, 10, 19, 8, 10))
        try store.closeOpen(at: at(2026, 10, 19, 8, 30))
        try store.open(mobileYoutube, at: at(2026, 10, 19, 8, 30))
        let allowance = Allowance(subject: .site(domain: "youtube.com"), amount: 30, unit: .minutes, per: .day)

        let used = try usage(allowance, store, now: at(2026, 10, 19, 8, 45))

        // 10 minutes in Chrome, then 15 in Safari so far; github.com in between doesn't count.
        #expect(used.used == 25 * 60)
        #expect(used.limit == 30 * 60)
        #expect(used.start == at(2026, 10, 19))
        #expect(used.end == at(2026, 10, 20))
        #expect(!used.isOver)
    }

    @Test func countsAnAppOrAProgram() throws {
        let store = try Store()
        try store.open(slack, at: at(2026, 10, 19, 8))
        try store.closeOpen(at: at(2026, 10, 19, 9))
        try store.open(claude, at: at(2026, 10, 19, 9))
        try store.closeOpen(at: at(2026, 10, 19, 9, 20))
        let now = at(2026, 10, 19, 12)

        let slackTime = try usage(
            Allowance(subject: .app(bundleID: slack.bundleID, name: "Slack"), amount: 1, unit: .hours, per: .day),
            store,
            now: now
        )
        let claudeTime = try usage(
            Allowance(subject: .program(name: "claude"), amount: 1, unit: .hours, per: .day),
            store,
            now: now
        )

        #expect(slackTime.used == 3600)
        #expect(slackTime.isOver)
        #expect(claudeTime.used == 20 * 60)
    }

    @Test func duringALabelCountsOnlyItsHours() throws {
        let store = try Store()
        // 8:30 to 9:30: half an hour before work, half an hour in it.
        try store.open(youtube, at: at(2026, 10, 19, 8, 30))
        try store.closeOpen(at: at(2026, 10, 19, 9, 30))
        let schedule = Schedule(labels: [work])
        let during = Allowance(
            subject: .site(domain: "youtube.com"),
            amount: 15,
            unit: .minutes,
            per: .day,
            during: .label(work.id)
        )
        var outside = during
        outside.during = .unscheduled

        #expect(try usage(during, store, now: at(2026, 10, 19, 12), schedule: schedule).used == 1800)
        #expect(try usage(outside, store, now: at(2026, 10, 19, 12), schedule: schedule).used == 1800)
    }

    @Test func aWeekStartsOnTheLocalesFirstDay() throws {
        let store = try Store()
        let allowance = Allowance(subject: .site(domain: "youtube.com"), amount: 5, unit: .hours, per: .week)

        let week = try usage(allowance, store, now: at(2026, 10, 21, 12))

        // Sunday 2026-10-18 to the next Sunday, in the US.
        #expect(week.start == at(2026, 10, 18))
        #expect(week.end == at(2026, 10, 25))
        #expect(week.limit == 5 * 3600)
    }

    @Test func runsOutAcrossTheWindowsThatCount() {
        let usage = Allowance.Usage(
            start: 0,
            end: 1000,
            windows: [.init(label: nil, start: 100, end: 200), .init(label: nil, start: 500, end: 600)],
            used: 0,
            limit: 150
        )

        // 50 seconds left in the first window at 150, then 100 more from 500.
        #expect(usage.instant(after: 150, from: 150) == 600)
        #expect(usage.instant(after: 0, from: 300) == 500)
        #expect(usage.instant(after: 151, from: 150) == nil)
    }

    @Test func underTheAllowanceLooksAgainWhenItRunsOut() {
        let usage = day(used: 600, limit: 1800)

        let next = usage.next(now: 5000, lastNotice: nil, reminder: 900)

        #expect(next.notify == false)
        #expect(next.at == 5000 + 1200)
    }

    @Test func underTheAllowanceAtTheEndOfThePeriodLooksAgainWhenItStartsOver() {
        let usage = day(used: 0, limit: 7200)

        #expect(usage.next(now: 86_000, lastNotice: nil, reminder: 900) == (false, 86_400))
    }

    @Test func overTheAllowanceNotifiesThenReminds() {
        let usage = day(used: 1800, limit: 1800)

        #expect(usage.next(now: 5000, lastNotice: nil, reminder: 900) == (true, 5900))
        // Back within 15 minutes of the last notice: wait for the reminder.
        #expect(usage.next(now: 5300, lastNotice: 5000, reminder: 900) == (false, 5900))
        #expect(usage.next(now: 5900, lastNotice: 5000, reminder: 900) == (true, 6800))
        // A notice from yesterday doesn't count.
        #expect(usage.next(now: 100, lastNotice: -50, reminder: 900) == (true, 1000))
    }

    @Test func overTheAllowanceOutsideItsLabelWaitsForTheLabel() {
        let usage = Allowance.Usage(
            start: 0,
            end: 86_400,
            windows: [.init(label: work.id, start: 32_400, end: 61_200)],
            used: 1800,
            limit: 900
        )

        #expect(usage.next(now: 62_000, lastNotice: nil, reminder: 900) == (false, 86_400))
        #expect(usage.next(now: 30_000, lastNotice: nil, reminder: 900) == (false, 32_400))
    }

    @Test func savesAllowancesAndReadsSchedulesFromBefore() throws {
        let old = #"{"labels":[]}"#
        #expect(try JSONDecoder().decode(Schedule.self, from: Data(old.utf8)) == Schedule())

        let schedule = Schedule(
            labels: [work],
            allowances: [
                Allowance(subject: .site(domain: "youtube.com"), amount: 30, unit: .minutes, per: .day),
                Allowance(subject: .program(name: "claude"), amount: 2, unit: .hours, per: .week, during: .unscheduled),
                Allowance(
                    subject: .app(bundleID: slack.bundleID, name: "Slack"),
                    amount: 1,
                    unit: .hours,
                    per: .month,
                    during: .label(work.id)
                ),
            ]
        )
        let data = try JSONEncoder().encode(schedule)

        #expect(try JSONDecoder().decode(Schedule.self, from: data) == schedule)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""during":"unscheduled""#))
        #expect(text.contains(#""during":"\#(work.id.uuidString)""#))
    }

    @Test func offersRecentAppsSitesAndProgramsButNotBrowsers() throws {
        let store = try Store()
        try store.open(chrome, at: at(2026, 10, 19, 8))
        try store.closeOpen(at: at(2026, 10, 19, 9))
        try store.open(slack, at: at(2026, 10, 19, 9))
        try store.closeOpen(at: at(2026, 10, 19, 9, 10))
        try store.open(claude, at: at(2026, 10, 19, 9, 10))
        try store.closeOpen(at: at(2026, 10, 19, 10))

        let recent = try Allowance.recent(store.database, now: at(2026, 10, 19, 12))

        #expect(
            recent == [
                .app(bundleID: "com.apple.Terminal", name: "Terminal"),
                .app(bundleID: slack.bundleID, name: "Slack"),
                .site(domain: "github.com"),
                .program(name: "claude"),
            ]
        )
    }

    @Test func describesAmountsInHoursAndMinutes() {
        #expect(Allowance.describe(45) == "45s")
        #expect(Allowance.describe(45 * 60) == "45m")
        #expect(Allowance.describe(90 * 60) == "1h 30m")
        #expect(Allowance.describe(2 * 3600 + 59) == "2h")
    }
}
