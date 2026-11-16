import ChronosCore
import Foundation
import SwiftUI

/// Labels for parts of the week, each with its hours. Saved as you go, while no two overlap.
struct ScheduleSettings: View {
    @Bindable var store: ScheduleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                """
                Labels name parts of your week, like Work from 9 to 5 on weekdays, so the viewer can show your time \
                by label. Time outside every label is Unscheduled. Labels only change how time is shown, never what's \
                recorded, so they apply to the past too.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if store.draft.labels.isEmpty {
                ContentUnavailableView {
                    Label("No Labels", systemImage: "calendar.badge.plus")
                } description: {
                    Text("All your time is Unscheduled.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($store.draft.labels) { $label in
                            LabelEditor(label: $label) { store.remove(label) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let conflict = store.draft.conflicts.first {
                Notice(symbol: "exclamationmark.triangle.fill", color: .orange) {
                    let note = Text("Not saved until fixed.").foregroundStyle(.secondary)
                    Text("\(conflict.first) and \(conflict.second) overlap \(describe(conflict.overlap)). \(note)")
                }
            } else if let error = store.error {
                Notice(symbol: "xmark.octagon.fill", color: .red) { Text(error) }
            }

            HStack {
                Button("Add Label", systemImage: "plus") {
                    withAnimation(.easeInOut(duration: 0.15)) { store.addLabel() }
                }
                Spacer()
                Text(Paths.schedule)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
    }

    /// "on Tuesday from 4:00 PM to 5:00 PM", from minutes after Sunday's midnight.
    private func describe(_ overlap: Range<Int>) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.standaloneWeekdaySymbols[overlap.lowerBound / Schedule.day]
        return "on \(day) from \(clock(overlap.lowerBound)) to \(clock(overlap.upperBound))"
    }
}

/// One label: its color, name, and hours, with the time they add up to each week.
private struct LabelEditor: View {
    @Binding var label: Schedule.Label
    let delete: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ColorWell(color: $label.color)
                    TextField("Name", text: $label.name, prompt: Text("Name, like Work"))
                        .textFieldStyle(.plain)
                        .font(.headline)
                    Text(weekly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Delete Label", systemImage: "trash", action: delete)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Delete \(label.title). Its time becomes Unscheduled; nothing recorded is lost.")
                }
                ForEach($label.hours) { $hours in
                    HoursEditor(hours: $hours, tint: label.color.color) {
                        label.hours.removeAll { $0.id == hours.id }
                    }
                }
                Button("Add Hours", systemImage: "plus.circle") {
                    label.hours.append(Schedule.Hours(days: [], start: 9 * 60, end: 17 * 60))
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(4)
        }
    }

    /// "40h a week".
    private var weekly: String {
        let minutes = label.hours.reduce(0) { $0 + $1.length * $1.days.count }
        let hours = Double(minutes) / 60
        return hours == hours.rounded() ? "\(Int(hours))h a week" : String(format: "%.1fh a week", hours)
    }
}

/// The same hours on some days: a toggle per day, in the order the week starts in, then from and to.
private struct HoursEditor: View {
    @Binding var hours: Schedule.Hours
    let tint: Color
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(weekdays, id: \.self) { day in
                    DayToggle(day: day, tint: tint, on: dayBinding(day))
                }
            }
            Spacer(minLength: 4)
            DatePicker("From", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                .labelsHidden()
            Text("to").foregroundStyle(.secondary)
            DatePicker("To", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
                .labelsHidden()
            Text("+1")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .help("Ends the next day")
                .opacity(hours.start + hours.length > Schedule.day ? 1 : 0)
            Button("Remove Hours", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    /// `Calendar` weekdays, from the locale's first.
    private var weekdays: [Int] {
        let first = Calendar.autoupdatingCurrent.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { hours.days.contains(day) },
            set: { on in
                if on { hours.days.insert(day) } else { hours.days.remove(day) }
            }
        )
    }

    /// Minutes after midnight, as a time today for the picker.
    private func timeBinding(_ keyPath: WritableKeyPath<Schedule.Hours, Int>) -> Binding<Date> {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        return Binding(
            get: {
                let minutes = hours[keyPath: keyPath]
                return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: today) ?? today
            },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                hours[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

/// A day's first letter, filled in the label's color when its hours include it.
private struct DayToggle: View {
    let day: Int
    let tint: Color
    @Binding var on: Bool

    var body: some View {
        let calendar = Calendar.autoupdatingCurrent
        Button {
            on.toggle()
        } label: {
            Text(calendar.veryShortStandaloneWeekdaySymbols[day - 1])
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(on ? .white : .secondary)
                .background(Circle().fill(on ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(calendar.standaloneWeekdaySymbols[day - 1])
        .animation(.easeInOut(duration: 0.1), value: on)
    }
}

/// The label's color as a dot that opens the choices.
private struct ColorWell: View {
    @Binding var color: Schedule.Tint
    @State private var choosing = false

    var body: some View {
        Button {
            choosing = true
        } label: {
            Circle().fill(color.color).frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Color")
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            HStack(spacing: 6) {
                ForEach(Schedule.Tint.allCases, id: \.self) { tint in
                    Button {
                        color = tint
                        choosing = false
                    } label: {
                        Circle().fill(tint.color).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.primary, lineWidth: tint == color ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(tint.rawValue.capitalized)
                }
            }
            .padding(12)
        }
    }
}

private struct Notice<Content: View>: View {
    let symbol: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            content().fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .transition(.opacity)
    }
}

/// "4:00 PM", or "16:00", as the locale writes times, for minutes after any midnight.
func clock(_ minutes: Int) -> String {
    let minutes = minutes % Schedule.day
    let calendar = Calendar.autoupdatingCurrent
    let today = calendar.startOfDay(for: Date())
    let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: today) ?? today
    return date.formatted(date: .omitted, time: .shortened)
}
