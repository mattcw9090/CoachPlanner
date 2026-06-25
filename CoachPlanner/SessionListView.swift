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

    private let dayStartHour = 6
    private let dayEndHour = 23
    private let hourHeight: CGFloat = 64
    private let timeAxisWidth: CGFloat = 42
    private let dayHeaderHeight: CGFloat = 46
    private let calendarHorizontalPadding: CGFloat = 12

    private var visibleHours: Range<Int> { dayStartHour..<dayEndHour }
    private var totalGridHeight: CGFloat { CGFloat(visibleHours.count) * hourHeight }

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

    private func dayOfMonth(for day: Weekday) -> Int {
        Calendar.current.component(.day, from: date(for: day))
    }

    private func isToday(_ day: Weekday) -> Bool {
        Calendar.current.isDateInToday(date(for: day))
    }

    private func sessions(for day: Weekday) -> [CoachingSession] {
        sessions.filter { $0.weekday == day }
    }

    private func minutesOfDay(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                weekBanner
                    .padding(.horizontal, calendarHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                dayHeaderRow
                    .padding(.horizontal, calendarHorizontalPadding)

                ScrollView(.vertical) {
                    grid
                        .frame(maxWidth: .infinity)
                    .padding(.horizontal, calendarHorizontalPadding)
                    .padding(.bottom, 28)
                }
            }
            .background(Color(.systemGroupedBackground))
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

    private var weekBanner: some View {
        Button {
            isWeekPickerPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)

                Text(weekRangeText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeAxisWidth, height: dayHeaderHeight)
            ForEach(Weekday.allCases) { day in
                Button {
                    editor = SessionEditor(preselectedDay: day)
                } label: {
                    VStack(spacing: 2) {
                        Text(String(day.name.prefix(3)))
                            .font(.caption2.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(isToday(day) ? Color.accentColor : Color.secondary)
                        Text("\(dayOfMonth(for: day))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isToday(day) ? .white : .primary)
                            .frame(width: 28, height: 28)
                            .background {
                                if isToday(day) {
                                    Circle().fill(Color.accentColor)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: dayHeaderHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
        .background(Color(.systemGroupedBackground))
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            timeAxis

            ForEach(Weekday.allCases) { day in
                dayColumn(for: day)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color(.separator).opacity(0.4))
                            .frame(width: 0.5)
                    }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var timeAxis: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear.frame(width: timeAxisWidth, height: totalGridHeight)
            ForEach(visibleHours, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
                    .offset(y: CGFloat(hour - dayStartHour) * hourHeight - 7)
            }
        }
        .frame(width: timeAxisWidth)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func dayColumn(for day: Weekday) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(visibleHours, id: \.self) { _ in
                    Rectangle()
                        .fill(Color(.separator).opacity(0.22))
                        .frame(height: 0.5)
                    Color.clear.frame(height: hourHeight - 0.5)
                }
            }

            ForEach(sessions(for: day)) { session in
                SessionBlock(session: session)
                    .frame(height: blockHeight(for: session))
                    .padding(.horizontal, 2)
                    .offset(y: yOffset(for: session))
                    .onTapGesture {
                        editor = SessionEditor(session: session)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalGridHeight)
        .background(Color(.secondarySystemGroupedBackground))
        .clipped()
    }

    private func yOffset(for session: CoachingSession) -> CGFloat {
        let mins = minutesOfDay(session.startTime) - dayStartHour * 60
        return CGFloat(mins) / 60.0 * hourHeight
    }

    private func blockHeight(for session: CoachingSession) -> CGFloat {
        let duration = minutesOfDay(session.endTime) - minutesOfDay(session.startTime)
        return max(CGFloat(duration) / 60.0 * hourHeight - 5, 30)
    }

    private func hourLabel(_ hour: Int) -> String {
        let cal = Calendar.current
        let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }

    static func monday(of date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? date
    }
}

private struct SessionBlock: View {
    let session: CoachingSession

    private var color: Color {
        session.statusValue.color
    }

    private var timeLabel: String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: session.startTime)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "a" : "p"

        if minute == 0 {
            return "\(displayHour)\(suffix)"
        }

        return "\(displayHour):\(String(format: "%02d", minute))\(suffix)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(timeLabel)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(session.venue)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.14))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(color)
                .frame(width: 2)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(color.opacity(0.28), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
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

#Preview {
    SessionListView()
        .modelContainer(for: [Student.self, CoachingSession.self], inMemory: true)
}
