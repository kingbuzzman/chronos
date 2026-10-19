import ChronosCore
import Foundation

// chronos-ff-host: Firefox starts it when chronos-ff connects, and ends it by closing stdin. It only relays: the
// extension's domain reports to the recorder, and the recorder's "current domain?" to the extension. It keeps nothing,
// and never starts Chronos.

// The recorder asks: pass it on to the extension. Answers come back through stdin like any other report.
let asking = DistributedNotificationCenter.default().addObserver(
    forName: FirefoxChannel.ask,
    object: nil,
    queue: .main
) { _ in
    FileHandle.standardOutput.write(NativeMessage.frame(#"{"ask":"domain"}"#))
}

// Reports from the extension: the domain only, passed on whether or not anyone is listening.
Thread.detachNewThread {
    var buffer = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        // Firefox closed the connection.
        if chunk.isEmpty { exit(0) }
        buffer.append(chunk)
        while let message = NativeMessage.next(from: &buffer) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                let domain = object["domain"] as? String, domain.count <= FirefoxChannel.longestDomain
            else { continue }
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

withExtendedLifetime(asking) { RunLoop.main.run() }
