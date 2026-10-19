package import Foundation

/// How the recorder and chronos-ff, the Firefox extension, reach each other. Firefox starts `chronos-ff-host` when the
/// extension connects and talks to it over stdin and stdout (native messaging); the host and the recorder talk through
/// distributed notifications. A notification nobody listens for goes nowhere, so with the recorder not running, the
/// extension's reports are simply dropped: nothing queues, and nothing starts Chronos.
package enum FirefoxChannel {
    /// Host → recorder: the domain of the tab in front, in `userInfo["domain"]`; '' when it has none.
    package static let domainReported = Notification.Name("com.kingbuzzman.chronos.ff.domain")
    /// Recorder → host: "what's the current domain?" The extension answers with a `domainReported`.
    package static let ask = Notification.Name("com.kingbuzzman.chronos.ff.ask")
    /// Longest domain passed on; anything longer isn't a domain.
    package static let longestDomain = 255

    package static let bundleIDs: Set = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
    ]
}

/// Native messaging's framing: each message is its length in 4 bytes, in the machine's byte order, then UTF-8 JSON.
package enum NativeMessage {
    /// Firefox sends at most 1 MB; anything claiming more means the stream is broken.
    private static let largest = 1024 * 1024

    package static func frame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var data = withUnsafeBytes(of: UInt32(body.count)) { Data($0) }
        data.append(body)
        return data
    }

    /// Takes the first whole message off the front of `buffer`, if one has fully arrived. A length that can't be right
    /// empties the buffer rather than reading garbage forever.
    package static func next(from buffer: inout Data) -> String? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
        guard length <= largest else {
            buffer.removeAll()
            return nil
        }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.dropFirst(4).prefix(length)
        buffer = Data(buffer.dropFirst(4 + length))
        return String(decoding: body, as: UTF8.self)
    }
}
