import ChronosCore
import Foundation
import Testing

struct FirefoxRegistrationTests {
    private let path = FileManager.default.temporaryDirectory.appendingPathComponent("ff-\(UUID().uuidString).json")
        .path

    private func write(_ json: String) throws {
        try json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func registration(path helper: String, name: String = FirefoxChannel.host) -> String {
        """
        {"name": "\(name)", "type": "stdio", "path": "\(helper)", "allowed_extensions": ["chronos-ff@kingbuzzman"]}
        """
    }

    @Test func noFileIsMissing() {
        #expect(FirefoxRegistration.check(at: path) == .missing)
    }

    @Test func aRunnableHostIsOK() throws {
        defer { try? FileManager.default.removeItem(atPath: path) }
        try write(registration(path: "/bin/sh"))

        #expect(FirefoxRegistration.check(at: path) == .ok(helper: "/bin/sh"))
    }

    @Test func aHostThatIsntThereIsMissing() throws {
        defer { try? FileManager.default.removeItem(atPath: path) }
        try write(registration(path: "/nowhere/Chronos.app/Contents/Helpers/chronos-ff-host"))

        #expect(
            FirefoxRegistration.check(at: path)
                == .helperMissing("/nowhere/Chronos.app/Contents/Helpers/chronos-ff-host")
        )
    }

    @Test func notJSONIsInvalid() throws {
        defer { try? FileManager.default.removeItem(atPath: path) }
        try write("HELPER_PATH")

        #expect(FirefoxRegistration.check(at: path) == .invalid("it isn't JSON"))
    }

    @Test func anotherNameIsInvalid() throws {
        defer { try? FileManager.default.removeItem(atPath: path) }
        try write(registration(path: "/bin/sh", name: "com.example.other"))

        #expect(FirefoxRegistration.check(at: path) == .invalid("its name isn't com.kingbuzzman.chronos"))
    }

    @Test func notAllowingChronosFFIsInvalid() throws {
        defer { try? FileManager.default.removeItem(atPath: path) }
        try write(#"{"name": "com.kingbuzzman.chronos", "type": "stdio", "path": "/bin/sh", "allowed_extensions": []}"#)

        #expect(FirefoxRegistration.check(at: path) == .invalid("it doesn't allow chronos-ff@kingbuzzman"))
    }
}

struct FirefoxHealthTests {
    private let registered = FirefoxRegistration.ok(
        helper: "/Applications/Chronos.app/Contents/Helpers/chronos-ff-host"
    )

    @Test func anAnswerIsHealthy() {
        let health = FirefoxHealth(
            firefoxRunning: true,
            registration: registered,
            helperAnswered: true,
            extensionAnswered: true
        )

        #expect(health.problem == nil)
    }

    @Test func anAnswerIsHealthyEvenFromAnOlderHostThatDoesntKnowPings() {
        let health = FirefoxHealth(firefoxRunning: true, registration: registered, extensionAnswered: true)

        #expect(health.problem == nil)
    }

    @Test func linesSayAnOlderHelperIsConnectedNotThatItIsnt() {
        let health = FirefoxHealth(firefoxRunning: true, registration: registered, extensionAnswered: true)

        #expect(
            health.lines(now: 0).dropFirst() == [
                "✓ chronos-ff is connected and answered with the site in front",
                "⚠︎ Its helper is an older version. Reload chronos-ff in Firefox to update it.",
            ]
        )
    }

    @Test func noHostMeansTheExtensionIsntConnected() {
        let health = FirefoxHealth(firefoxRunning: true, registration: registered)

        #expect(health.problem == .notConnected)
    }

    @Test func aHostButNoDomainMeansTheExtensionIsntAnswering() {
        let health = FirefoxHealth(firefoxRunning: true, registration: registered, helperAnswered: true, rejected: 3)

        #expect(health.problem == .notAnswering(rejected: 3))
        #expect(FirefoxHealth.describe(health.problem!).contains("threw away 3 of its messages"))
    }

    @Test func aBrokenRegistrationComesFirst() {
        #expect(FirefoxHealth(firefoxRunning: true, registration: .missing).problem == .notRegistered)
        #expect(
            FirefoxHealth(firefoxRunning: true, registration: .helperMissing("/gone")).problem
                == .helperMissing("/gone")
        )
    }

    @Test func withFirefoxClosedOnlyTheRegistrationCounts() {
        #expect(FirefoxHealth(firefoxRunning: false, registration: registered).problem == nil)
        #expect(FirefoxHealth(firefoxRunning: false, registration: .missing).problem == .notRegistered)
    }

    @Test func linesShowEachLink() {
        let health = FirefoxHealth(
            firefoxRunning: true,
            registration: registered,
            helperAnswered: true,
            lastReport: 1_000
        )

        #expect(
            health.lines(now: 1_000 + 720) == [
                "✓ Registered with Firefox: /Applications/Chronos.app/Contents/Helpers/chronos-ff-host",
                "✗ chronos-ff is connected, but didn't answer with the site in front",
                "Last site from chronos-ff: 12m ago",
            ]
        )
    }

    @Test func linesShowABrokenRegistrationEvenWhileDomainsArrive() {
        let health = FirefoxHealth(
            firefoxRunning: true,
            registration: .missing,
            helperAnswered: true,
            extensionAnswered: true
        )

        #expect(health.problem == nil)
        #expect(health.lines(now: 0).first == "✗ Firefox doesn't know where Chronos's helper is. Run make ff-register.")
    }
}
