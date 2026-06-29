import SwiftData
import SwiftUI

struct SocialSessionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\SocialSession.weekStart),
            SortDescriptor(\SocialSession.dayOfWeek),
            SortDescriptor(\SocialSession.startTime)
        ]
    ) private var socialSessions: [SocialSession]

    @AppStorage("weekStartTimestamp") private var weekStartTimestamp: Double = 0
    @State private var editor: SocialSessionEditor?

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
        return "\(weekStart.formatted(formatter)) - \(weekEnd.formatted(formatter))"
    }

    private var sessionsForWeek: [SocialSession] {
        socialSessions.filter { Calendar.current.isDate($0.weekStart, inSameDayAs: weekStart) }
    }

    private var totalStudents: Int {
        sessionsForWeek.reduce(0) { $0 + $1.students.count }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Socials Week")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(weekRangeText)
                                    .font(.title3.weight(.semibold))
                            }

                            Spacer()

                            HStack(spacing: 8) {
                                Button {
                                    moveWeek(by: -1)
                                } label: {
                                    Image(systemName: "chevron.left")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    moveWeek(by: 1)
                                } label: {
                                    Image(systemName: "chevron.right")
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        HStack(spacing: 10) {
                            MetricTile(
                                title: "Socials",
                                value: "\(sessionsForWeek.count)",
                                systemImage: "figure.badminton",
                                tint: .purple
                            )
                            MetricTile(
                                title: "Names",
                                value: "\(totalStudents)",
                                systemImage: "person.2.fill",
                                tint: .blue
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)

                if sessionsForWeek.isEmpty {
                    ContentUnavailableView {
                        Label("No Socials Planned", systemImage: "figure.badminton")
                    } description: {
                        Text("Add a badminton socials session and attach the students attending that week.")
                    } actions: {
                        Button("Add Socials Session") {
                            editor = SocialSessionEditor(weekStart: weekStart)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(Weekday.allCases) { day in
                        let daySessions = sessionsForWeek.filter { $0.weekday == day }
                        if !daySessions.isEmpty {
                            Section(day.name) {
                                ForEach(daySessions) { session in
                                    Button {
                                        editor = SocialSessionEditor(session: session, weekStart: weekStart)
                                    } label: {
                                        SocialSessionRow(session: session)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .onDelete { offsets in
                                    deleteSessions(at: offsets, from: daySessions)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Socials")
            .scrollContentBackground(.hidden)
            .background(AppStyle.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = SocialSessionEditor(weekStart: weekStart)
                    } label: {
                        Label("Add Socials", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editor) { editor in
                SocialSessionEditorView(editor: editor)
            }
            .onAppear {
                if weekStartTimestamp == 0 {
                    weekStartTimestamp = Self.monday(of: .now).timeIntervalSince1970
                }
            }
        }
    }

    private func moveWeek(by offset: Int) {
        let nextWeek = Calendar.current.date(byAdding: .day, value: offset * 7, to: weekStart) ?? weekStart
        weekStartTimestamp = Self.monday(of: nextWeek).timeIntervalSince1970
    }

    private func deleteSessions(at offsets: IndexSet, from sessions: [SocialSession]) {
        let toDelete = offsets.map { sessions[$0] }
        for session in toDelete {
            modelContext.delete(session)
        }
    }

    static func monday(of date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? date
    }
}

private struct SocialSessionRow: View {
    let session: SocialSession

    private var sortedStudents: [Student] {
        session.students.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "figure.badminton")
                    .font(.headline)
                    .foregroundStyle(.purple)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.purple.opacity(0.14)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("\(timeRangeText(start: session.startTime, end: session.endTime)) · \(session.venue)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(sortedStudents.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.purple.opacity(0.14)))
            }

            if sortedStudents.isEmpty {
                Text("No students added yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(sortedStudents.map(\.name).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }

            if !session.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(session.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    private func timeRangeText(start: Date, end: Date) -> String {
        "\(start.formatted(.dateTime.hour().minute()))-\(end.formatted(.dateTime.hour().minute()))"
    }
}

struct SocialSessionEditor: Identifiable {
    let id = UUID()
    let session: SocialSession?
    let weekStart: Date

    init(session: SocialSession? = nil, weekStart: Date) {
        self.session = session
        self.weekStart = SocialSessionListView.monday(of: weekStart)
    }
}

private struct SocialSessionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Student.name) private var students: [Student]

    let editor: SocialSessionEditor

    @State private var title: String
    @State private var dayOfWeek: Weekday
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var venue: Venue
    @State private var notes: String
    @State private var selectedStudentIDs: Set<PersistentIdentifier>
    @State private var studentSearch = ""

    private var isEditing: Bool { editor.session != nil }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(editor: SocialSessionEditor) {
        self.editor = editor

        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: .now) ?? .now
        let defaultEnd = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: .now) ?? .now

        _title = State(initialValue: editor.session?.title ?? "Badminton Socials")
        _dayOfWeek = State(initialValue: editor.session?.weekday ?? .friday)
        _startTime = State(initialValue: editor.session?.startTime ?? defaultStart)
        _endTime = State(initialValue: editor.session?.endTime ?? defaultEnd)
        _venue = State(initialValue: editor.session?.venueValue ?? .pbaMalaga)
        _notes = State(initialValue: editor.session?.notes ?? "")
        _selectedStudentIDs = State(
            initialValue: Set(editor.session?.students.map(\.persistentModelID) ?? [])
        )
    }

    private var selectedStudents: [Student] {
        students
            .filter { selectedStudentIDs.contains($0.persistentModelID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var availableStudents: [Student] {
        let trimmed = studentSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return students
            .filter { !selectedStudentIDs.contains($0.persistentModelID) }
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var isTimeValid: Bool {
        minutesOfDay(endTime) > minutesOfDay(startTime)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Session name", text: $title)

                    Picker("Day", selection: $dayOfWeek) {
                        ForEach(Weekday.allCases) { day in
                            Text(day.name).tag(day)
                        }
                    }

                    Picker("Venue", selection: $venue) {
                        ForEach(Venue.allCases) { venue in
                            Text(venue.rawValue).tag(venue)
                        }
                    }

                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                } header: {
                    Text("Socials Details")
                } footer: {
                    if !isTimeValid {
                        Text("End time must be after start time.")
                            .foregroundStyle(.red)
                    }
                }

                Section("Name List") {
                    TextField("Search students", text: $studentSearch)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    if selectedStudents.isEmpty {
                        Text("No students selected")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedStudents) { student in
                            HStack {
                                Label(student.name, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button("Remove") {
                                    selectedStudentIDs.remove(student.persistentModelID)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("Add Students") {
                    if availableStudents.isEmpty {
                        Text(students.isEmpty ? "Add students in the Students tab first." : "No matching students.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(availableStudents) { student in
                            Button {
                                selectedStudentIDs.insert(student.persistentModelID)
                                studentSearch = ""
                            } label: {
                                HStack {
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

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                if isEditing {
                    Section {
                        Button("Delete Socials Session", role: .destructive) {
                            deleteSession()
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Socials" : "New Socials")
            .navigationBarTitleDisplayMode(.inline)
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
                    .disabled(trimmedTitle.isEmpty || !isTimeValid)
                }
            }
        }
    }

    private func save() {
        let selected = students.filter { selectedStudentIDs.contains($0.persistentModelID) }

        if let session = editor.session {
            session.title = trimmedTitle
            session.weekStart = editor.weekStart
            session.dayOfWeek = dayOfWeek.rawValue
            session.startTime = startTime
            session.endTime = endTime
            session.venue = venue.rawValue
            session.notes = trimmedNotes
            session.students = selected
        } else {
            let session = SocialSession(
                title: trimmedTitle,
                weekStart: editor.weekStart,
                dayOfWeek: dayOfWeek,
                startTime: startTime,
                endTime: endTime,
                venue: venue,
                notes: trimmedNotes,
                students: selected
            )
            modelContext.insert(session)
        }

        dismiss()
    }

    private func deleteSession() {
        if let session = editor.session {
            modelContext.delete(session)
        }
        dismiss()
    }

    private func minutesOfDay(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}

#Preview {
    SocialSessionListView()
        .modelContainer(for: [Student.self, CoachingSession.self, CourtBooking.self, SocialSession.self], inMemory: true)
}
