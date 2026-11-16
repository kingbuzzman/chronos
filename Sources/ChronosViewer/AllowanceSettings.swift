import AppKit
import ChronosCore
import Foundation
import SwiftUI

/// Allowances: time for an app, a site or a Terminal program, a day, week or month. Saved as you go.
struct AllowanceSettings: View {
    @Bindable var store: ScheduleStore
    @State private var usage: [UUID: Allowance.Usage] = [:]
    @State private var recent: [Allowance.Subject] = []
    @State private var addingSite = false
    @State private var site = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                """
                Give an app, a site or a Terminal program so much time a day, week or month, any time or only during \
                a label. Go over and Chronos sends a notification, then another every 15 minutes you stay. It never \
                closes or blocks anything. Browsers have no allowance of their own; their sites do.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if store.draft.allowances.isEmpty {
                ContentUnavailableView {
                    Label("No Allowances", systemImage: "hourglass")
                } description: {
                    Text("Nothing has a limit.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($store.draft.allowances) { $allowance in
                            AllowanceEditor(
                                allowance: $allowance,
                                labels: store.draft.labels,
                                usage: usage[allowance.id]
                            ) { store.remove(allowance) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let error = store.error {
                Notice(symbol: "xmark.octagon.fill", color: .red) { Text(error) }
            }

            addMenu
        }
        .padding(20)
        .onAppear(perform: loadRecent)
        .onChange(of: store.draft.allowances) { loadUsage() }
        .onChange(of: store.draft.labels) { loadUsage() }
        // The time used keeps counting while the pane is open.
        .task {
            while !Task.isCancelled {
                loadUsage()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .alert("Add a Site", isPresented: $addingSite) {
            TextField("Site", text: $site, prompt: Text("youtube.com"))
            Button("Add") { addSite() }
            Button("Cancel", role: .cancel) { site = "" }
        } message: {
            Text("Its subdomains count too: google.com includes docs.google.com.")
        }
    }

    /// What's been used lately, to pick from, and any other site by name.
    private var addMenu: some View {
        let apps = recent.filter { if case .app = $0 { true } else { false } }
        let sites = recent.filter { if case .site = $0 { true } else { false } }
        let programs = recent.filter { if case .program = $0 { true } else { false } }
        return Menu {
            section("Apps", apps)
            section("Sites", sites)
            section("Terminal Programs", programs)
            Divider()
            Button("Another Site…") { addingSite = true }
        } label: {
            Label("Add Allowance", systemImage: "plus")
        }
        .fixedSize()
    }

    @ViewBuilder private func section(_ title: String, _ subjects: [Allowance.Subject]) -> some View {
        if !subjects.isEmpty {
            Section(title) {
                ForEach(subjects, id: \.self) { subject in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { store.addAllowance(for: subject) }
                    } label: {
                        Label {
                            Text(subject.name)
                        } icon: {
                            SubjectIcon(subject: subject, size: 16)
                        }
                    }
                }
            }
        }
    }

    private func addSite() {
        defer { site = "" }
        guard let domain = Host.of(site), !domain.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) { store.addAllowance(for: .site(domain: domain)) }
    }

    private func loadRecent() {
        guard let database = try? Database(path: Paths.database, readOnly: true) else { return }
        recent = (try? Allowance.recent(database, now: Int(Date().timeIntervalSince1970))) ?? []
    }

    private func loadUsage() {
        guard let database = try? Database(path: Paths.database, readOnly: true) else { return }
        let now = Date()
        var usage: [UUID: Allowance.Usage] = [:]
        for allowance in store.draft.allowances {
            usage[allowance.id] = try? allowance.usage(
                database,
                schedule: store.draft,
                at: now,
                calendar: .autoupdatingCurrent
            )
        }
        self.usage = usage
    }
}

/// One allowance as a sentence, "30 minutes a day during Work", under its subject and how much is used.
private struct AllowanceEditor: View {
    @Binding var allowance: Allowance
    let labels: [Schedule.Label]
    let usage: Allowance.Usage?
    let delete: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SubjectIcon(subject: allowance.subject, size: 18)
                    Text(allowance.subject.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let usage {
                        Text(used(usage))
                            .font(.caption)
                            .foregroundStyle(usage.isOver ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .monospacedDigit()
                    }
                    Button("Delete Allowance", systemImage: "trash", action: delete)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Delete this allowance. Nothing recorded changes.")
                }
                HStack(spacing: 6) {
                    TextField("Amount", value: amount, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                    Picker("Unit", selection: $allowance.unit) {
                        Text("minutes").tag(Allowance.Unit.minutes)
                        Text("hours").tag(Allowance.Unit.hours)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("a").foregroundStyle(.secondary)
                    Picker("Per", selection: $allowance.per) {
                        ForEach(Allowance.Per.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("During", selection: $allowance.during) {
                        Text("any time").tag(Allowance.During?.none)
                        if !labels.isEmpty {
                            Divider()
                            ForEach(labels) { label in
                                Text("during \(label.title)").tag(Allowance.During?.some(.label(label.id)))
                            }
                            Text("outside labels").tag(Allowance.During?.some(.unscheduled))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                ProgressView(value: fraction)
                    .tint(usage?.isOver == true ? .red : tint)
            }
            .padding(4)
        }
    }

    /// At least 1: an allowance of nothing would only nag.
    private var amount: Binding<Int> {
        Binding(get: { allowance.amount }, set: { allowance.amount = max($0, 1) })
    }

    private var fraction: Double {
        guard let usage, usage.limit > 0 else { return 0 }
        return min(Double(usage.used) / Double(usage.limit), 1)
    }

    /// The label's color when it counts during one, otherwise the accent color.
    private var tint: Color {
        guard case .label(let id) = allowance.during, let label = labels.first(where: { $0.id == id }) else {
            return .accentColor
        }
        return label.color.color
    }

    /// "12m of 30m today", or "45m of 30m today, 15m over".
    private func used(_ usage: Allowance.Usage) -> String {
        let text =
            "\(Allowance.describe(usage.used)) of \(Allowance.describe(usage.limit)) \(allowance.per.period.phrase)"
        guard usage.used > usage.limit else { return text }
        return text + ", \(Allowance.describe(usage.used - usage.limit)) over"
    }
}

/// An app's own icon, or a symbol for a site or a program.
private struct SubjectIcon: View {
    let subject: Allowance.Subject
    let size: CGFloat

    var body: some View {
        switch subject {
        case .app(let bundleID, _):
            Image(nsImage: Self.resized(AppIcons.icon(for: bundleID), to: size))
        case .site:
            Image(systemName: "globe").frame(width: size, height: size)
        case .program:
            Image(systemName: "terminal").frame(width: size, height: size)
        }
    }

    /// A copy at `size` points, since a menu shows an image at its own size.
    private static func resized(_ image: NSImage, to size: CGFloat) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: size, height: size)
        return copy
    }
}
