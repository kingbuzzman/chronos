import AppKit
import ChronosCore
import Foundation
import SwiftUI

/// What Chronos is, which version this is, where it lives online, and what it has recorded so far.
struct AboutView: View {
    private static let project = URL(string: "https://github.com/kingbuzzman/chronos")!
    @State private var lifetime: Lifetime?

    var body: some View {
        VStack(spacing: 14) {
            // The app icon, but its hands tell the time.
            TimelineView(.everyMinute) { context in
                Image(nsImage: Self.icon(at: context.date)).resizable().frame(width: 96, height: 96)
                    .help(context.date.formatted(date: .omitted, time: .shortened))
            }

            VStack(spacing: 4) {
                Text("Chronos").font(.largeTitle.weight(.semibold))
                Text(versionLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            VStack(spacing: 6) {
                Text("Know where your day actually went.").font(.headline)
                Text(
                    """
                    Chronos quietly keeps track of which app you're using and for how long, and in a browser or \
                    Terminal, which site or program. Everything stays in one file on your Mac.
                    """
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            }

            HStack(spacing: 18) {
                Link(destination: Self.project) {
                    Label("Project", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: releaseNotes) { Label("Release Notes", systemImage: "doc.text") }
                Link(destination: Self.project.appendingPathComponent("issues/new")) {
                    Label("Report an Issue", systemImage: "ladybug")
                }
            }
            .font(.callout)

            Divider().padding(.horizontal, 40)

            if let lifetime, let since = lifetime.since {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    stat(
                        "Recording since",
                        Date(timeIntervalSince1970: TimeInterval(since)).formatted(date: .long, time: .omitted)
                    )
                    stat(
                        "Time recorded",
                        formatDuration(lifetime.seconds),
                        help: formatDurationPrecisely(lifetime.seconds)
                    )
                    stat("Apps seen", lifetime.apps.formatted())
                    stat("Switches", lifetime.switches.formatted())
                }
                .font(.callout)
            }

            HStack(spacing: 6) {
                Text(Paths.database)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.database)])
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Spacer(minLength: 0)
            Text("Released under the MIT License.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .onAppear(perform: load)
    }

    /// "Version 0.1.5", or a note that this build didn't come from `make`, which is what sets the version.
    private var versionLine: String {
        guard let version else { return "Development build" }
        return "Version \(version)"
    }

    private var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// This version's release, or every release for a development build.
    private var releaseNotes: URL {
        guard let version else { return Self.project.appendingPathComponent("releases") }
        return Self.project.appendingPathComponent("releases/tag/v\(version)")
    }

    private func stat(_ title: String, _ value: String, help: String? = nil) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospacedDigit().help(help ?? value)
        }
    }

    private func load() {
        lifetime = try? Lifetime.read(Database(path: Paths.database, readOnly: true))
    }

    private static func icon(at date: Date) -> NSImage {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        let time = (parts.hour ?? 10) * 60 + (parts.minute ?? 10)
        return NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            Logo.drawAppIcon(in: context, size: rect.width, time: time)
            return true
        }
    }
}
