import ChronosCore
import Foundation

/// A calendar in a zone with daylight saving, so the tests see 23- and 25-hour days.
let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

/// Unix seconds for a local time in New York.
func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Int {
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    return Int(newYork.date(from: components)!.timeIntervalSince1970)
}

let chrome = Target(bundleID: "com.google.Chrome", name: "Google Chrome", domain: "github.com")
let claude = Target(bundleID: "com.apple.Terminal", name: "Terminal", program: "claude")
let slack = Target(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
let xcode = Target(bundleID: "com.apple.dt.Xcode", name: "Xcode")

struct SlotRow: Equatable {
    let bundleID: String
    let domain: String
    let program: String?
    let start: Int
    let end: Int?
    let duration: Int?
    let continued: Bool
}

extension Store {
    convenience init() throws {
        try self.init(path: ":memory:", calendar: newYork)
    }

    var slots: [SlotRow] {
        get throws {
            try database.rows(
                """
                SELECT a.bundle_id, s.domain, p.bundle_id, s.started_at, s.ended_at, s.duration, s.continued
                FROM slots s JOIN apps a ON a.id = s.app_id LEFT JOIN apps p ON p.id = s.sub_app_id ORDER BY s.id
                """
            ) {
                SlotRow(
                    bundleID: $0.text(0),
                    domain: $0.text(1),
                    program: $0.isNull(2) ? nil : $0.text(2),
                    start: $0.int(3),
                    end: $0.isNull(4) ? nil : $0.int(4),
                    duration: $0.isNull(5) ? nil : $0.int(5),
                    continued: $0.int(6) == 1
                )
            }
        }
    }
}

/// A clock the tests move by hand.
final class FakeClock {
    var time: Double

    init(_ time: Int) {
        self.time = Double(time)
    }

    func advance(_ seconds: Double) {
        time += seconds
    }
}
