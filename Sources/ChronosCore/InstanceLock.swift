import Darwin

/// One recorder at a time, however it was started: a second copy of the app, the same app opened with `open -n`, or
/// its program run directly. Two would both write, each closing the other's open slot.
///
/// An exclusive `flock` on a file, held for as long as the process runs. The system drops it when the process ends,
/// crashes included, so a stale lock can't keep Chronos from starting.
package final class InstanceLock {
    package struct LockError: Error, CustomStringConvertible {
        package let description: String
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// The lock, or nil if another process holds it.
    package static func acquire(path: String) throws -> InstanceLock? {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw LockError(description: "\(path): \(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return InstanceLock(descriptor: descriptor)
    }
}
