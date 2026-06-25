import SwiftData
import SwiftUI

struct SessionEditor: Identifiable {
    let id = UUID()
    let session: CoachingSession?
    let preselectedDay: Weekday?

    init(session: CoachingSession? = nil, preselectedDay: Weekday? = nil) {
        self.session = session
        self.preselectedDay = preselectedDay
    }
}

struct SessionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Student.name) private var students: [Student]
    @Query private var existingSessions: [CoachingSession]

    let editor: SessionEditor

    @State private var dayOfWeek: Weekday
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var venue: Venue
    @State private var status: SessionStatus
    @State private var selectedStudentIDs: Set<PersistentIdentifier>
    @State private var studentSearch: String = ""
    @State private var hasUserAdjustedStart: Bool = false
    @State private var hasUserAdjustedEnd: Bool = false
    @State private var hasUserAdjustedVenue: Bool = false
    @FocusState private var isSearchFocused: Bool

    init(editor: SessionEditor) {
        self.editor = editor
        let initialDay = editor.session?.weekday ?? editor.preselectedDay ?? .monday
        _dayOfWeek = State(initialValue: initialDay)

        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: .now) ?? .now
        let defaultEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now

        _startTime = State(initialValue: editor.session?.startTime ?? defaultStart)
        _endTime = State(initialValue: editor.session?.endTime ?? defaultEnd)
        _venue = State(initialValue: editor.session?.venueValue ?? .pbaMalaga)
        _status = State(initialValue: editor.session?.statusValue ?? .unscheduled)
        _selectedStudentIDs = State(
            initialValue: Set(editor.session?.students.map(\.persistentModelID) ?? [])
        )
    }

    private var isEditing: Bool {
        editor.session != nil
    }

    private var isTimeRangeValid: Bool {
        minutes(of: endTime) > minutes(of: startTime)
    }

    private var overlappingSession: CoachingSession? {
        let editingID = editor.session?.persistentModelID
        let newStart = minutes(of: startTime)
        let newEnd = minutes(of: endTime)

        return existingSessions.first { session in
            session.persistentModelID != editingID &&
                session.dayOfWeek == dayOfWeek.rawValue &&
                newStart < minutes(of: session.endTime) &&
                newEnd > minutes(of: session.startTime)
        }
    }

    private var canSave: Bool {
        isTimeRangeValid && overlappingSession == nil && !selectedStudentIDs.isEmpty
    }

    private var selectedStudentsList: [Student] {
        students.filter { selectedStudentIDs.contains($0.persistentModelID) }
    }

    private var filteredStudentMatches: [Student] {
        let trimmed = studentSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let unselected = students.filter { !selectedStudentIDs.contains($0.persistentModelID) }
        guard !trimmed.isEmpty else { return unselected }
        return unselected.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Day of Week", selection: $dayOfWeek) {
                        ForEach(Weekday.allCases) { day in
                            Text(day.name).tag(day)
                        }
                    }

                    LabeledContent("Start Time") {
                        HalfHourTimePicker(selection: Binding(
                            get: { startTime },
                            set: { newValue in
                                startTime = newValue
                                hasUserAdjustedStart = true
                                if !hasUserAdjustedEnd,
                                   let autoEnd = Calendar.current.date(byAdding: .hour, value: 1, to: newValue) {
                                    endTime = autoEnd
                                }
                            }
                        ))
                    }

                    LabeledContent("End Time") {
                        HalfHourTimePicker(selection: Binding(
                            get: { endTime },
                            set: { newValue in
                                endTime = newValue
                                hasUserAdjustedEnd = true
                            }
                        ))
                    }

                    Picker("Venue", selection: Binding(
                        get: { venue },
                        set: { newValue in
                            venue = newValue
                            hasUserAdjustedVenue = true
                        }
                    )) {
                        ForEach(Venue.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }

                    Picker("Status", selection: $status) {
                        ForEach(SessionStatus.allCases) { option in
                            HStack {
                                Image(systemName: option.iconName)
                                    .foregroundStyle(option.color)
                                Text(option.rawValue)
                            }
                            .tag(option)
                        }
                    }
                } header: {
                    Text("Session Details")
                } footer: {
                    if !isTimeRangeValid {
                        Text("End time must be after start time.")
                            .foregroundStyle(.red)
                    } else if let overlap = overlappingSession {
                        Text("Overlaps with \(overlap.weekday.name) \(timeRangeText(for: overlap)) at \(overlap.venue).")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    if students.isEmpty {
                        Text("Add students first before assigning them to sessions.")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search students", text: $studentSearch)
                                .focused($isSearchFocused)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !studentSearch.isEmpty {
                                Button {
                                    studentSearch = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        if !studentSearch.isEmpty {
                            if filteredStudentMatches.isEmpty {
                                Text("No matches")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(filteredStudentMatches) { student in
                                    Button {
                                        selectedStudentIDs.insert(student.persistentModelID)
                                        studentSearch = ""
                                    } label: {
                                        HStack {
                                            Image(systemName: "person.crop.circle.fill")
                                                .foregroundStyle(iconColor(for: student))
                                            Text(student.name)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: "plus.circle.fill")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Students")
                } footer: {
                    if !students.isEmpty && selectedStudentIDs.isEmpty {
                        Text("Select at least one student.")
                            .foregroundStyle(.red)
                    }
                }

                if !selectedStudentsList.isEmpty {
                    Section("Selected (\(selectedStudentsList.count))") {
                        StudentChipFlow(spacing: 6) {
                            ForEach(selectedStudentsList) { student in
                                StudentChip(
                                    name: student.name,
                                    color: iconColor(for: student)
                                ) {
                                    selectedStudentIDs.remove(student.persistentModelID)
                                }
                            }
                        }
                    }
                }

                if isEditing {
                    Section {
                        Button("Delete Session", role: .destructive) {
                            deleteSession()
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Session" : "New Session")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                applyAutoFillIfNeeded()
            }
            .onChange(of: dayOfWeek) { _, _ in
                applyAutoFillIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func minutes(of date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private func applyAutoFillIfNeeded() {
        guard !isEditing,
              !hasUserAdjustedStart,
              !hasUserAdjustedEnd,
              !hasUserAdjustedVenue else { return }

        let calendar = Calendar.current
        let sameDaySessions = existingSessions.filter {
            $0.dayOfWeek == dayOfWeek.rawValue
        }

        let startMinutes: Int
        if let latest = sameDaySessions.max(by: { minutes(of: $0.endTime) < minutes(of: $1.endTime) }) {
            if let latestVenue = Venue(rawValue: latest.venue) {
                venue = latestVenue
            }
            startMinutes = minutes(of: latest.endTime)
        } else {
            startMinutes = 17 * 60
        }

        let clampedStart = min(startMinutes, 23 * 60)
        let clampedEnd = min(clampedStart + 60, 24 * 60 - 1)

        if let newStart = calendar.date(bySettingHour: clampedStart / 60, minute: clampedStart % 60, second: 0, of: .now),
           let newEnd = calendar.date(bySettingHour: clampedEnd / 60, minute: clampedEnd % 60, second: 0, of: .now) {
            startTime = newStart
            endTime = newEnd
        }
    }

    private func timeRangeText(for session: CoachingSession) -> String {
        let formatter = Date.FormatStyle.dateTime.hour().minute()
        return "\(session.startTime.formatted(formatter))–\(session.endTime.formatted(formatter))"
    }

    private func iconColor(for student: Student) -> Color {
        switch student.gender {
        case "Female": return .pink
        case "Male": return .blue
        default: return .gray
        }
    }

    private func save() {
        let selectedStudents = students.filter { student in
            selectedStudentIDs.contains(student.persistentModelID)
        }

        if let session = editor.session {
            session.dayOfWeek = dayOfWeek.rawValue
            session.startTime = startTime
            session.endTime = endTime
            session.venue = venue.rawValue
            session.status = status.rawValue
            session.students = selectedStudents
        } else {
            let session = CoachingSession(
                dayOfWeek: dayOfWeek,
                startTime: startTime,
                endTime: endTime,
                venue: venue,
                status: status,
                students: selectedStudents
            )
            modelContext.insert(session)
        }

        dismiss()
    }

    private func deleteSession() {
        guard let session = editor.session else { return }
        modelContext.delete(session)
        dismiss()
    }
}

private struct HalfHourTimePicker: View {
    @Binding var selection: Date

    private var minutesBinding: Binding<Int> {
        Binding(
            get: {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: selection)
                let raw = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                return (raw / 30) * 30
            },
            set: { newMinutes in
                let calendar = Calendar.current
                if let newDate = calendar.date(
                    bySettingHour: newMinutes / 60,
                    minute: newMinutes % 60,
                    second: 0,
                    of: selection
                ) {
                    selection = newDate
                }
            }
        )
    }

    var body: some View {
        Picker("", selection: minutesBinding) {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { totalMinutes in
                Text(label(for: totalMinutes)).tag(totalMinutes)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func label(for totalMinutes: Int) -> String {
        let hour = totalMinutes / 60
        let minute = totalMinutes % 60
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour().minute())
    }
}

private struct StudentChip: View {
    let name: String
    let color: Color
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(color.opacity(0.15))
        )
    }
}

private struct StudentChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRowWidth + size.width > maxWidth && currentRowWidth > 0 {
                totalHeight += currentRowHeight + spacing
                currentRowWidth = size.width + spacing
                currentRowHeight = size.height
            } else {
                currentRowWidth += size.width + spacing
                currentRowHeight = max(currentRowHeight, size.height)
            }
        }
        totalHeight += currentRowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : currentRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += currentRowHeight + spacing
                currentRowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}
