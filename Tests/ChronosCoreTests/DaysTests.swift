import ChronosCore
import Testing

struct DaysTests {
    @Test func noCutWithinADay() {
        #expect(Days.midnights(after: at(2026, 10, 19, 9), before: at(2026, 10, 19, 17), calendar: newYork) == [])
    }

    @Test func endingExactlyAtMidnightIsNotACut() {
        #expect(Days.midnights(after: at(2026, 10, 19, 22), before: at(2026, 10, 20), calendar: newYork) == [])
    }

    @Test func startingExactlyAtMidnightIsNotACut() {
        #expect(Days.midnights(after: at(2026, 10, 20), before: at(2026, 10, 20, 1), calendar: newYork) == [])
    }

    @Test func cutsAtEveryMidnight() {
        let cuts = Days.midnights(after: at(2026, 10, 19, 22), before: at(2026, 10, 22, 0, 10), calendar: newYork)

        #expect(cuts == [at(2026, 10, 20), at(2026, 10, 21), at(2026, 10, 22)])
    }

    @Test func daysAroundClockChangesAreLocalMidnights() {
        // 2026-03-08 is 23 hours long in New York, and 2026-11-01 is 25.
        #expect(at(2026, 3, 9) - at(2026, 3, 8) == 23 * 3600)
        #expect(at(2026, 11, 2) - at(2026, 11, 1) == 25 * 3600)

        #expect(
            Days.midnights(after: at(2026, 3, 7, 12), before: at(2026, 3, 9, 12), calendar: newYork)
                == [at(2026, 3, 8), at(2026, 3, 9)]
        )
        #expect(
            Days.midnights(after: at(2026, 10, 31, 12), before: at(2026, 11, 2, 12), calendar: newYork)
                == [at(2026, 11, 1), at(2026, 11, 2)]
        )
    }
}
