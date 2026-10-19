import ChronosCore
import Testing

struct HostTests {
    @Test(arguments: [
        ("https://www.github.com/multimediallc/chaturbate/pull/123", "github.com"),
        ("https://docs.google.com/document/d/abc?tab=t.0#heading", "docs.google.com"),
        ("HTTPS://WWW.Example.COM/Path", "example.com"),
        ("http://localhost:8000/admin", "localhost:8000"),
        ("https://user:secret@example.com/", "example.com"),
        ("chrome://settings/privacy", "chrome://settings"),
        ("chrome-extension://abcdef/popup.html", "chrome-extension://abcdef"),
        ("file:///Users/javier/notes.html", "file://"),
        ("about:blank", "about:blank"),
        ("data:text/html,<p>secret</p>", "data:"),
        // Firefox's address bar shows addresses without a scheme.
        ("github.com/multimediallc", "github.com"),
        ("localhost:3000/login", "localhost:3000"),
        ("  https://example.com  ", "example.com"),
    ])
    func keepsOnlyTheHost(url: String, host: String) {
        #expect(Host.of(url) == host)
    }

    @Test(arguments: ["", "   ", "https://"])
    func nothingForAnEmptyAddress(url: String) {
        #expect(Host.of(url) == nil)
    }
}
