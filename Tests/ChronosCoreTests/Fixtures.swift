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

/// A row of `input`: a chunk's input while one target was in front.
struct InputRow: Equatable {
    let start: Int
    let bundleID: String
    let domain: String
    let keys: Int
    let clicks: Int

    init(_ start: Int, _ target: Target, keys: Int, clicks: Int = 0) {
        self.start = start
        bundleID = target.bundleID
        domain = target.domain
        self.keys = keys
        self.clicks = clicks
    }

    init(start: Int, bundleID: String, domain: String, keys: Int, clicks: Int) {
        self.start = start
        self.bundleID = bundleID
        self.domain = domain
        self.keys = keys
        self.clicks = clicks
    }
}

extension Store {
    var input: [InputRow] {
        get throws {
            try database.rows(
                """
                SELECT i.started_at, a.bundle_id, i.domain, i.keys, i.clicks
                FROM input i JOIN apps a ON a.id = i.app_id ORDER BY i.id
                """
            ) {
                InputRow(start: $0.int(0), bundleID: $0.text(1), domain: $0.text(2), keys: $0.int(3), clicks: $0.int(4))
            }
        }
    }
}

/// Running input totals the tests add to by hand.
final class FakeInput {
    var counts = InputCounts()

    func type(_ keys: UInt32) {
        counts.keys &+= keys
    }

    func click(_ clicks: UInt32) {
        counts.clicks &+= clicks
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
