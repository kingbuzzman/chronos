import AppKit
import ChronosCore
import Foundation

// Only one recorder runs: any other copy ends here, before recording anything or showing its icon. Held until exit.
let lock: InstanceLock?
do {
    try FileManager.default.createDirectory(atPath: Paths.folder, withIntermediateDirectories: true)
    lock = try InstanceLock.acquire(path: Paths.lock)
} catch {
    lock = nil
    NSLog("Chronos: can't take its lock, \(error)")
}
guard lock != nil else {
    NSLog("Chronos is already running; this copy is quitting.")
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
