import ChronosCore
import Foundation
import Testing

struct InstanceLockTests {
    /// In the temporary folder, which macOS clears on its own.
    private let path = FileManager.default.temporaryDirectory.appendingPathComponent(
        "chronos-\(UUID().uuidString).lock"
    )
    .path

    @Test func aSecondCopyCantTakeTheLock() throws {
        let first = try InstanceLock.acquire(path: path)

        #expect(first != nil)
        #expect(try InstanceLock.acquire(path: path) == nil)
        withExtendedLifetime(first) {}
    }

    @Test func theLockIsFreeOnceItsHolderIsGone() throws {
        var first = try InstanceLock.acquire(path: path)
        #expect(first != nil)

        first = nil

        #expect(try InstanceLock.acquire(path: path) != nil)
    }

    @Test func aLockInAMissingFolderIsAnError() {
        #expect(throws: InstanceLock.LockError.self) { try InstanceLock.acquire(path: "/no/such/folder/chronos.lock") }
    }
}
