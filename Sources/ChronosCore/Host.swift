import Foundation

/// Reduces a browser's URL to what Chronos stores: the host, never the path, query or fragment.
package enum Host {
    /// Schemes whose URLs have no `//`. Anything else without `://` is an address bar's text, such as Firefox's
    /// `github.com/foo`, and is read as https.
    private static let opaqueSchemes = ["about", "data", "javascript", "blob", "mailto"]

    /// - `https://www.github.com/a/b?c` → `github.com`
    /// - `http://localhost:8000/admin` → `localhost:8000`
    /// - `chrome://settings/privacy` → `chrome://settings`
    /// - `file:///Users/me/notes.html` → `file://`
    /// - `about:blank` → `about:blank`; `data:…` → `data:`
    package static func of(_ url: String) -> String? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let scheme = text.prefix { $0 != ":" }.lowercased()
        if !text.contains("://"), !opaqueSchemes.contains(scheme) { text = "https://" + text }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "http", "https":
            guard var host = components.host?.lowercased(), !host.isEmpty else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return components.port.map { "\(host):\($0)" } ?? host
        case "file":
            return "file://"
        case "about":
            return "about:\(components.path)"
        default:
            guard let host = components.host, !host.isEmpty else { return "\(scheme):" }
            return "\(scheme)://\(host.lowercased())"
        }
    }
}
