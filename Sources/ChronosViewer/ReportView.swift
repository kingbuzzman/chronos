import AppKit
import ChronosCore
import Foundation
import Observation
import SwiftUI

/// Reads the database read-only. The one change the viewer makes, forgetting a site, goes through a connection opened
/// for just that.
@MainActor @Observable final class ReportModel {
    /// Every app's time, or one label's, or unscheduled time.
    enum Slice: Hashable {
        case all
        /// A label by its ID, or unscheduled time for `nil`.
        case label(UUID?)
    }

    let schedule: ScheduleStore
    var period = Period.day
    var slice = Slice.all
    private var all: [AppTotal] = []
    /// Each label's apps, and unscheduled time's under `nil`. Empty while there are no labels.
    private(set) var byLabel: [UUID?: [AppTotal]] = [:]
    private var failure: String?

    init(schedule: ScheduleStore) {
        self.schedule = schedule
    }

    /// The apps in the slice on screen.
    var apps: [AppTotal] {
        switch slice {
        case .all: all
        case .label(let id): byLabel[id] ?? []
        }
    }

    var total: Int { apps.reduce(0) { $0 + $1.seconds } }

    func seconds(in label: UUID?) -> Int {
        byLabel[label]?.reduce(0) { $0 + $1.seconds } ?? 0
    }

    var message: String? {
        if let failure { return failure }
        guard apps.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: Paths.database) else {
            return "Nothing recorded yet. Chronos records while it's running."
        }
        switch slice {
        case .all: return "Nothing recorded \(period.phrase)."
        case .label(nil): return "No unscheduled time \(period.phrase)."
        case .label(let id?):
            let name = schedule.saved.labels.first { $0.id == id }?.title ?? "this label"
            return "Nothing recorded during \(name) \(period.phrase)."
        }
    }

    func load() {
        let labels = schedule.saved.labels
        // A label that's been deleted can't stay selected.
        if case .label(let id?) = slice, !labels.contains(where: { $0.id == id }) { slice = .all }
        if labels.isEmpty { slice = .all }
        guard FileManager.default.fileExists(atPath: Paths.database) else {
            (all, byLabel, failure) = ([], [:], nil)
            return
        }
        do {
            let database = try Database(path: Paths.database, readOnly: true)
            try Schema.checkReadable(database)
            let now = Date()
            all = try Report.apps(database, in: period, at: now, calendar: .autoupdatingCurrent)
            byLabel =
                labels.isEmpty
                ? [:]
                : try Report.apps(database, in: period, at: now, by: schedule.saved, calendar: .autoupdatingCurrent)
            failure = nil
        } catch {
            (all, byLabel, failure) = ([], [:], "\(error)")
        }
    }

    /// Clears `site` from `app` over all time; its time stays, as "Not identified".
    func forget(_ site: String, in app: AppTotal) {
        do {
            try Forget.site(site, in: app.bundleID, Database(path: Paths.database))
        } catch {
            failure = "\(error)"
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
                    .contentTransition(.numericText())
                Text(caption).foregroundStyle(.secondary)
            }

            if !model.schedule.saved.labels.isEmpty {
                LabelStrip(model: model)
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
                // The bars take the color of the label on screen.
                .tint(sliceColor)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.period) { model.load() }
        .onChange(of: model.schedule.saved) { withAnimation(.easeInOut(duration: 0.15)) { model.load() } }
    }

    /// "today", or "of Work today".
    private var caption: String {
        switch model.slice {
        case .all: model.period.phrase
        case .label(nil): "unscheduled \(model.period.phrase)"
        case .label(let id?):
            "of \(model.schedule.saved.labels.first { $0.id == id }?.title ?? "") \(model.period.phrase)"
        }
    }

    private var sliceColor: Color? {
        switch model.slice {
        case .all: nil
        case .label(nil): .gray
        case .label(let id?): model.schedule.saved.labels.first { $0.id == id }?.color.color
        }
    }
}

/// The period's time split by label: a bar with each label's share in its color, and a chip per label, plus
/// Unscheduled, to show only its apps. Clicking the chip on screen goes back to all of them.
private struct LabelStrip: View {
    @Bindable var model: ReportModel

    private struct Part: Identifiable {
        let id: UUID?
        let title: String
        let color: Color
        let seconds: Int
    }

    private var parts: [Part] {
        model.schedule.saved.labels.map {
            Part(id: $0.id, title: $0.title, color: $0.color.color, seconds: model.seconds(in: $0.id))
        } + [Part(id: nil, title: "Unscheduled", color: .gray.opacity(0.45), seconds: model.seconds(in: nil))]
    }

    var body: some View {
        let parts = parts
        let total = parts.reduce(0) { $0 + $1.seconds }
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { space in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.seconds > 0 }) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(
                                width: max(2, (space.size.width - 2 * CGFloat(parts.count)) * share(part, of: total))
                            )
                            .opacity(isDimmed(part) ? 0.3 : 1)
                            .help(
                                "\(part.title): \(formatDurationPrecisely(part.seconds)), \(percent(part, of: total))"
                            )
                            .onTapGesture { select(part) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 8)
            .clipShape(Capsule())
            .background(Capsule().fill(.quaternary))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(parts) { part in
                        Chip(
                            title: part.title,
                            detail: formatDuration(part.seconds),
                            color: part.color,
                            selected: model.slice == .label(part.id)
                        ) { select(part) }
                        .help("\(formatDurationPrecisely(part.seconds)), \(percent(part, of: total))")
                    }
                }
                // Room for the selected chip's outline, which the scroll view would otherwise clip.
                .padding(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.slice)
    }

    private func share(_ part: Part, of total: Int) -> Double {
        total > 0 ? Double(part.seconds) / Double(total) : 0
    }

    private func percent(_ part: Part, of total: Int) -> String {
        share(part, of: total).formatted(.percent.precision(.fractionLength(0)))
    }

    private func isDimmed(_ part: Part) -> Bool {
        model.slice != .all && model.slice != .label(part.id)
    }

    private func select(_ part: Part) {
        withAnimation(.easeInOut(duration: 0.15)) {
            model.slice = model.slice == .label(part.id) ? .all : .label(part.id)
        }
    }
}

private struct Chip: View {
    let title: String
    let detail: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).lineLimit(1)
                Text(detail).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? AnyShapeStyle(color.opacity(0.2)) : AnyShapeStyle(.quinary)))
            .overlay(Capsule().strokeBorder(selected ? color : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
