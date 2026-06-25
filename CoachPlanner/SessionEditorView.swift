import SwiftData
import SwiftUI

struct SessionEditor: Identifiable {
    let id = UUID()
    let session: CoachingSession?

    init(session: CoachingSession? = nil) {
        self.session = session
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
    @State private var selectedStudentIDs: Set<PersistentIdentifier>

    init(editor: SessionEditor) {
        self.editor = editor
        _dayOfWeek = State(initialValue: editor.session?.weekday ?? .monday)

        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: .now) ?? .now
        let defaultEnd = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: .now) ?? .now

        _startTime = State(initialValue: editor.session?.startTime ?? defaultStart)
        _endTime = State(initialValue: editor.session?.endTime ?? defaultEnd)
        _venue = State(initialValue: editor.session?.venueValue ?? .pbaMalaga)
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Day of Week", selection: $dayOfWeek) {
                        ForEach(Weekday.allCases) { day in
                            Text(day.name).tag(day)
                        }
                    }

                    DatePicker(
                        "Start Time",
                        selection: $startTime,
                        displayedComponents: .hourAndMinute
                    )

                    DatePicker(
                        "End Time",
                        selection: $endTime,
                        displayedComponents: .hourAndMinute
                    )

                    Picker("Venue", selection: $venue) {
                        ForEach(Venue.allCases) { option in
                            Text(option.rawValue).tag(option)
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
                        ForEach(students) { student in
                            Button {
                                toggleStudent(student)
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle.fill")
                                        .foregroundStyle(iconColor(for: student))

                                    Text(student.name)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    if selectedStudentIDs.contains(student.persistentModelID) {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
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

    private func toggleStudent(_ student: Student) {
        let id = student.persistentModelID

        if selectedStudentIDs.contains(id) {
            selectedStudentIDs.remove(id)
        } else {
            selectedStudentIDs.insert(id)
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
            session.students = selectedStudents
        } else {
            let session = CoachingSession(
                dayOfWeek: dayOfWeek,
                startTime: startTime,
                endTime: endTime,
                venue: venue,
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
