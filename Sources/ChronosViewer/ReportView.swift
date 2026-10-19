import AppKit
import ChronosCore
import Foundation
import Observation
import SwiftUI

/// Reads the database read-only. The one change the viewer makes, forgetting a site, goes through a connection opened
/// for just that.
@MainActor @Observable final class ReportModel {
    var period = Period.day
    private(set) var apps: [AppTotal] = []
    private(set) var message: String?

    var total: Int { apps.reduce(0) { $0 + $1.seconds } }

    func load() {
        let path = Paths.database
        guard FileManager.default.fileExists(atPath: path) else {
            apps = []
            message = "Nothing recorded yet. Chronos records while it's running."
            return
        }
        do {
            let database = try Database(path: path, readOnly: true)
            try Schema.checkReadable(database)
            apps = try Report.apps(database, in: period, at: Date(), calendar: .autoupdatingCurrent)
            message = apps.isEmpty ? "Nothing recorded \(period.phrase)." : nil
        } catch {
            apps = []
            message = "\(error)"
        }
    }

    /// Clears `site` from `app` over all time; its time stays, as "Not identified".
    func forget(_ site: String, in app: AppTotal) {
        do {
            try Forget.site(site, in: app.bundleID, Database(path: Paths.database))
        } catch {
            message = "\(error)"
            return
        }
        withAnimation(.easeInOut(duration: 0.15)) { load() }
    }
}

struct ReportView: View {
    @Bindable var model: ReportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Period", selection: $model.period) {
                ForEach(Period.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatDuration(model.total))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .help(formatDurationPrecisely(model.total))
                Text(model.period.phrase).foregroundStyle(.secondary)
            }

            if let message = model.message {
                Spacer()
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.apps, id: \.bundleID) { app in
                            AppRow(app: app, longest: model.apps.first?.seconds ?? 1) { model.forget($0, in: app) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.period) { model.load() }
    }
}

/// One app's time. Apps Chronos can see into, such as Terminal and browsers, open to show what ran inside them:
/// programs or sites, each with its time. Closed until clicked.
private struct AppRow: View {
    let app: AppTotal
    /// The top app's time, which a full bar stands for.
    let longest: Int
    /// Called with a site's name when its ✕ is clicked.
    let forget: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14)
                    // Keeps every app's icon in line, whether or not it opens.
                    .opacity(app.parts.isEmpty ? 0 : 1)
                TimeRow(title: app.name, seconds: app.seconds, fraction: fraction(app.seconds, of: longest)) {
                    Image(nsImage: AppIcons.icon(for: app.bundleID)).resizable()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !app.parts.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }
            if expanded {
                // Bars here show each part's share of the app's time.
                ForEach(app.parts, id: \.name) { part in
                    PartRow(
                        part: part,
                        fraction: fraction(part.seconds, of: app.seconds),
                        forget: part.kind == .site ? { forget(part.name) } : nil
                    )
                }
            }
        }
    }

    private func fraction(_ seconds: Int, of whole: Int) -> Double {
        whole > 0 ? Double(seconds) / Double(whole) : 0
    }
}

/// What ran inside an app, indented under it. A site's row shows a ✕ while the pointer is over it, at the far left,
/// in line with the apps' chevrons.
private struct PartRow: View {
    let part: AppTotal.Part
    let fraction: Double
    let forget: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            // The room is always there, so the row doesn't move when the ✕ shows. The ✕ is left out rather than made
            // transparent while not hovering: a transparent button still takes clicks.
            Color.clear
                .frame(width: 14, height: 14)
                .overlay {
                    if hovering, let forget {
                        Button(action: forget) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Forget this site. Its time stays, as Not identified.")
                    }
                }
            TimeRow(
                title: part.kind == .unidentified ? "Not identified" : part.name,
                seconds: part.seconds,
                fraction: fraction,
                dimmed: part.kind == .unidentified
            ) {
                Image(systemName: part.kind.symbol).foregroundStyle(.secondary)
            }
            // With the ✕'s room, the same 40 points the rows were always indented by.
            .padding(.leading, 26)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// An icon, a name, a bar and a duration.
private struct TimeRow<Icon: View>: View {
    let title: String
    let seconds: Int
    let fraction: Double
    var dimmed = false
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 8) {
            icon().frame(width: 18, height: 18)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .frame(minWidth: 90, maxWidth: 170, alignment: .leading)
            GeometryReader { space in
                Capsule()
                    .fill(dimmed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint))
                    .frame(width: max(3, space.size.width * fraction), height: 6)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            Text(formatDuration(seconds))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 3)
        // Anywhere on the row, not just over the number.
        .contentShape(Rectangle())
        .help(formatDurationPrecisely(seconds))
    }
}

/// Apps' own icons, looked up once each.
@MainActor private enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let icon = cache[bundleID] { return icon }
        let icon =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        cache[bundleID] = icon
        return icon
    }
}

extension AppTotal.Part.Kind {
    fileprivate var symbol: String {
        switch self {
        case .program: "terminal"
        case .site: "globe"
        case .unidentified: "questionmark.circle"
        }
    }
}

extension Period {
    fileprivate var phrase: String {
        switch self {
        case .day: "today"
        case .week: "this week"
        case .month: "this month"
        case .year: "this year"
        }
    }
}
