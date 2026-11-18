import ChronosCore
import Foundation
import os

// chronos-ff-host: Firefox starts it when chronos-ff connects, and ends it by closing stdin. It only relays: the
// extension's domain reports to the recorder, and the recorder's "current domain?" to the extension. It keeps nothing,
// and never starts Chronos. What it does goes to the system log, domains redacted:
// log stream --predicate 'subsystem == "com.kingbuzzman.chronos"' --level debug

let log = Logger(subsystem: BundleID.recorder, category: "ff-host")
/// The extension's messages so far: domains passed on, and anything else, thrown away. For the recorder's ping.
let counts = OSAllocatedUnfairLock(initialState: (passed: 0, rejected: 0))

log.notice("Started by Firefox, pid \(ProcessInfo.processInfo.processIdentifier)")
// Tells the extension Firefox could start its host, which it can't otherwise know until a question comes.
FileHandle.standardOutput.write(NativeMessage.frame(#"{"hello":"chronos-ff-host"}"#))

// The recorder asks: pass it on to the extension. Answers come back through stdin like any other report.
let asking = DistributedNotificationCenter.default().addObserver(
    forName: FirefoxChannel.ask,
    object: nil,
    queue: .main
) { _ in
    log.debug("Chronos asked for the domain")
    FileHandle.standardOutput.write(NativeMessage.frame(#"{"ask":"domain"}"#))
}

// The recorder checks the host is running.
let pinging = DistributedNotificationCenter.default().addObserver(
    forName: FirefoxChannel.ping,
    object: nil,
    queue: .main
) { _ in
    let (passed, rejected) = counts.withLock { $0 }
    log.debug("Chronos pinged: \(passed) passed on, \(rejected) thrown away")
    DistributedNotificationCenter.default().postNotificationName(
        FirefoxChannel.pong,
        object: nil,
        userInfo: ["passed": passed, "rejected": rejected],
        deliverImmediately: true
    )
}

// Reports from the extension: the domain only, passed on whether or not anyone is listening.
Thread.detachNewThread {
    var buffer = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty {
            log.notice("Firefox closed the channel")
            exit(0)
        }
        buffer.append(chunk)
        while let message = NativeMessage.next(from: &buffer) {
            let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
            guard let domain = object?["domain"] as? String, domain.count <= FirefoxChannel.longestDomain else {
                counts.withLock { $0.rejected += 1 }
                log.error("Threw away a message from chronos-ff that isn't a domain: \(message.utf8.count) bytes")
                continue
            }
            counts.withLock { $0.passed += 1 }
            log.debug("Passing on \(domain, privacy: .private)")
            DistributedNotificationCenter.default().postNotificationName(
                FirefoxChannel.domainReported,
                object: nil,
                userInfo: ["domain": domain],
                // Chronos runs in the background, where notifications are otherwise held until it comes to the front.
                deliverImmediately: true
            )
        }
    }
}

withExtendedLifetime((asking, pinging)) { RunLoop.main.run() }
