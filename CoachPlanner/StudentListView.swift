import SwiftData
import SwiftUI

private enum StudentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case male = "Male"
    case female = "Female"
    case underallocated = "Underallocated"

    var id: String { rawValue }
}

struct StudentListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Student.name) private var students: [Student]
    @Query private var sessions: [CoachingSession]

    @State private var editor: StudentEditor?
    @State private var filter: StudentFilter = .all

    private var sessionCountByStudent: [PersistentIdentifier: Int] {
        var counts: [PersistentIdentifier: Int] = [:]
        for session in sessions {
            for student in session.students {
                counts[student.persistentModelID, default: 0] += 1
            }
        }
        return counts
    }

    private func sessionCount(for student: Student) -> Int {
        sessionCountByStudent[student.persistentModelID] ?? 0
    }

    private func isUnderallocated(_ student: Student) -> Bool {
        sessionCount(for: student) < student.sessionsDemand
    }

    private var underallocatedCount: Int {
        students.filter(isUnderallocated).count
    }

    private var weeklyDemand: Int {
        students.reduce(0) { $0 + $1.sessionsDemand }
    }

    private var allocatedSessions: Int {
        sessionCountByStudent.values.reduce(0, +)
    }

    private func count(for filter: StudentFilter) -> Int {
        switch filter {
        case .all: return students.count
        case .male: return students.filter { $0.gender == "Male" }.count
        case .female: return students.filter { $0.gender == "Female" }.count
        case .underallocated: return students.filter(isUnderallocated).count
        }
    }

    private var filteredStudents: [Student] {
        switch filter {
        case .all: return students
        case .male: return students.filter { $0.gender == "Male" }
        case .female: return students.filter { $0.gender == "Female" }
        case .underallocated: return students.filter(isUnderallocated)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if students.isEmpty {
                    ContentUnavailableView {
                        Label("No Students Yet", systemImage: "figure.badminton")
                    } description: {
                        Text("Add your first badminton student to get started.")
                    } actions: {
                        Button("Add Student") {
                            editor = StudentEditor()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            HStack(spacing: 8) {
                                MetricTile(
                                    title: "Students",
                                    value: "\(students.count)",
                                    systemImage: "person.3.fill",
                                    tint: .blue
                                )
                                MetricTile(
                                    title: "Needs",
                                    value: "\(underallocatedCount)",
                                    systemImage: "exclamationmark.circle.fill",
                                    tint: underallocatedCount == 0 ? .green : .red
                                )
                                MetricTile(
                                    title: "Booked",
                                    value: "\(allocatedSessions)/\(weeklyDemand)",
                                    systemImage: "calendar.badge.clock",
                                    tint: .accentColor
                                )
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)

                        Section {
                            Picker("Filter", selection: $filter) {
                                ForEach(StudentFilter.allCases) { option in
                                    Text("\(option.rawValue) (\(count(for: option)))")
                                        .tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        }

                        Section {
                            ForEach(filteredStudents) { student in
                                Button {
                                    editor = StudentEditor(student: student)
                                } label: {
                                    StudentRow(
                                        student: student,
                                        sessionCount: sessionCount(for: student),
                                        demand: student.sessionsDemand
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete(perform: deleteStudents)
                        } header: {
                            Text("\(filteredStudents.count) \(filteredStudents.count == 1 ? "student" : "students")")
                        }
                    }
                }
            }
            .navigationTitle("My Students")
            .scrollContentBackground(.hidden)
            .background(AppStyle.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = StudentEditor()
                    } label: {
                        Label("Add Student", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editor) { editor in
                StudentEditorView(editor: editor)
            }
        }
    }

    private func deleteStudents(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredStudents[$0] }
        for student in toDelete {
            modelContext.delete(student)
        }
    }
}

private struct StudentRow: View {
    let student: Student
    let sessionCount: Int
    let demand: Int

    private var iconColor: Color {
        AppStyle.genderColor(for: student.gender)
    }

    private var badgeColor: Color {
        sessionCount < demand ? .red : .secondary
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 40, height: 40)
                .background(Circle().fill(iconColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(student.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 5) {
                    Image(systemName: student.contactPreferenceValue.iconName)
                        .font(.caption2)
                    Text("\(student.contactPreferenceValue.rawValue): \(student.displayContactDetail)")
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.caption)
                Text("\(sessionCount) / \(demand)")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(badgeColor.opacity(0.12))
            )

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}

#Preview {
    StudentListView()
        .modelContainer(for: [Student.self, CoachingSession.self], inMemory: true)
}
