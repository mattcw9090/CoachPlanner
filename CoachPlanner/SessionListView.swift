import SwiftData
import SwiftUI

struct SessionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\CoachingSession.dayOfWeek),
            SortDescriptor(\CoachingSession.startTime)
        ]
    ) private var sessions: [CoachingSession]

    @AppStorage("weekStartTimestamp") private var weekStartTimestamp: Double = 0

    @State private var editor: SessionEditor?
    @State private var isWeekPickerPresented = false

    private var weekStart: Date {
        if weekStartTimestamp == 0 {
            return Self.monday(of: .now)
        }
        return Date(timeIntervalSince1970: weekStartTimestamp)
    }

    private var weekEnd: Date {
        Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
    }

    private var weekRangeText: String {
        let formatter = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return "Week of \(weekStart.formatted(formatter)) – \(weekEnd.formatted(formatter))"
    }

    private func date(for day: Weekday) -> Date {
        Calendar.current.date(byAdding: .day, value: day.rawValue - 1, to: weekStart) ?? weekStart
    }

    private func dateLabel(for day: Weekday) -> String {
        date(for: day).formatted(.dateTime.month(.abbreviated).day())
    }

    private var groupedSessions: [(day: Weekday, sessions: [CoachingSession])] {
        let groups = Dictionary(grouping: sessions, by: { $0.weekday })
        return Weekday.allCases.compactMap { day in
            guard let daySessions = groups[day], !daySessions.isEmpty else { return nil }
            return (day, daySessions)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Sessions Yet", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("Add a session and choose which students will attend.")
                    } actions: {
                        Button("Add Session") {
                            editor = SessionEditor()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            Button {
                                isWeekPickerPresented = true
                            } label: {
                                HStack {
                                    Image(systemName: "calendar")
                                        .foregroundStyle(.tint)
                                    Text(weekRangeText)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "pencil")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        ForEach(groupedSessions, id: \.day) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    Button {
                                        editor = SessionEditor(session: session)
                                    } label: {
                                        SessionRow(session: session)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .onDelete { offsets in
                                    delete(from: group.sessions, at: offsets)
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Text(group.day.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .textCase(nil)

                                    Text(dateLabel(for: group.day))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)

                                    Spacer()

                                    Text("\(group.sessions.count) \(group.sessions.count == 1 ? "session" : "sessions")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = SessionEditor()
                    } label: {
                        Label("Add Session", systemImage: "plus")
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isWeekPickerPresented = true
                    } label: {
                        Label("Set Week", systemImage: "calendar")
                    }
                }
            }
            .sheet(item: $editor) { editor in
                SessionEditorView(editor: editor)
            }
            .sheet(isPresented: $isWeekPickerPresented) {
                WeekStartPickerView(currentStart: weekStart) { newStart in
                    weekStartTimestamp = newStart.timeIntervalSince1970
                }
            }
        }
    }

    private func delete(from daySessions: [CoachingSession], at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(daySessions[index])
        }
    }

    static func monday(of date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? date
    }
}

private struct WeekStartPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let currentStart: Date
    let onSave: (Date) -> Void

    @State private var selectedDate: Date

    init(currentStart: Date, onSave: @escaping (Date) -> Void) {
        self.currentStart = currentStart
        self.onSave = onSave
        _selectedDate = State(initialValue: currentStart)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MondayCalendarPicker(selection: $selectedDate)
                        .padding(.vertical, 8)
                } footer: {
                    Text("Week of \(selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())).")
                }

                Section {
                    Button("Use current week") {
                        selectedDate = SessionListView.monday(of: .now)
                    }
                }
            }
            .navigationTitle("Set Week Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(selectedDate)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct MondayCalendarPicker: View {
    @Binding var selection: Date
    @State private var visibleMonth: Date

    init(selection: Binding<Date>) {
        self._selection = selection
        self._visibleMonth = State(initialValue: selection.wrappedValue)
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal
    }

    private var firstDayOfMonth: Date {
        let comps = calendar.dateComponents([.year, .month], from: visibleMonth)
        return calendar.date(from: comps) ?? visibleMonth
    }

    private var daysInMonth: Range<Int> {
        calendar.range(of: .day, in: .month, for: visibleMonth) ?? 1..<32
    }

    private var leadingEmptyDays: Int {
        let weekday = calendar.component(.weekday, from: firstDayOfMonth)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    stepMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)

                Spacer()

                Button {
                    stepMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<leadingEmptyDays, id: \.self) { _ in
                    Color.clear.frame(height: 36)
                }
                ForEach(daysInMonth, id: \.self) { day in
                    let date = calendar.date(byAdding: .day, value: day - 1, to: firstDayOfMonth) ?? firstDayOfMonth
                    let isMonday = calendar.component(.weekday, from: date) == 2
                    let isSelected = calendar.isDate(date, inSameDayAs: selection)

                    DayCell(day: day, isMonday: isMonday, isSelected: isSelected) {
                        selection = date
                    }
                }
            }
        }
    }

    private func stepMonth(_ delta: Int) {
        if let new = calendar.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = new
        }
    }
}

private struct DayCell: View {
    let day: Int
    let isMonday: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text("\(day)")
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(textColor)
                .background {
                    if isSelected {
                        Circle().fill(Color.accentColor)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!isMonday)
    }

    private var textColor: Color {
        if !isMonday { return .secondary.opacity(0.4) }
        if isSelected { return .white }
        return .primary
    }
}

private struct SessionRow: View {
    let session: CoachingSession

    private var timeRange: String {
        let formatter = Date.FormatStyle.dateTime.hour().minute()
        return "\(session.startTime.formatted(formatter)) – \(session.endTime.formatted(formatter))"
    }

    private var studentNames: String {
        session.students
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.name)
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Image(systemName: "clock.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(timeRange)
                    .font(.headline)

                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption)
                    Text(session.venue)
                        .font(.subheadline)
                }
                .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                    Text(studentNames)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

#Preview {
    SessionListView()
        .modelContainer(for: [Student.self, CoachingSession.self], inMemory: true)
}
