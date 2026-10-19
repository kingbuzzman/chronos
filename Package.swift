// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "chronos",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Chronos", targets: ["Chronos"]),
        .executable(name: "ChronosViewer", targets: ["ChronosViewer"]),
        .executable(name: "chronos-ff-host", targets: ["ChronosFirefoxHost"]),
    ],
    targets: [
        // The database, its schema and the rules for writing and reading slots, shared by both apps.
        .target(name: "ChronosCore"),
        // The recorder: menu bar icon, focus events, all writes.
        .executableTarget(name: "Chronos", dependencies: ["ChronosCore"]),
        // The viewer: reads the database and draws the charts.
        .executableTarget(name: "ChronosViewer", dependencies: ["ChronosCore"]),
        // Relays between chronos-ff, the Firefox extension, and the recorder. Firefox starts it; shipped inside the app.
        .executableTarget(name: "ChronosFirefoxHost", dependencies: ["ChronosCore"]),
        // Draws the app icon at build time, from the same code as the menu bar icon. Not shipped.
        .executableTarget(name: "IconMaker", dependencies: ["ChronosCore"]),
        .testTarget(name: "ChronosCoreTests", dependencies: ["ChronosCore"]),
    ]
)

/// Every target: the Swift 6 language mode, which checks for data races, plus every feature the compiler lists as a
/// Swift 7 default, and a failed build on any compiler or linker warning (no compiler setting covers the linker's).
for target in package.targets {
    target.swiftSettings = [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .treatAllWarnings(as: .error),
    ]
    target.linkerSettings = [.unsafeFlags(["-Xlinker", "-fatal_warnings"])]
}
