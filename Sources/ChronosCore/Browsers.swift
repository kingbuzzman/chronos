/// The browsers Chronos reads a site from, by bundle ID. Their time is split by site, so an allowance is set on a
/// site rather than on the browser.
package enum Browsers {
    /// Chrome and the browsers built on it, which answer AppleScript the same way.
    package static let chromium: Set = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
    ]

    package static let safari: Set = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    package static var all: Set<String> { chromium.union(safari).union(FirefoxChannel.bundleIDs) }
}
