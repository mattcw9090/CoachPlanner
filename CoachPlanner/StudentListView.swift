import SwiftData
import SwiftUI

private enum GenderFilter: String, CaseIterable, Identifiable {
    case male = "Male"
    case female = "Female"

    var id: String { rawValue }
}

private enum AllocationFilter: String, CaseIterable, Identifiable {
    case underallocated = "Underallocated"
    case overallocated = "Overallocated"

    var id: String { rawValue }
}

struct StudentListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Student.name) private var students: [Student]
    @Query private var sessions: [CoachingSession]

    @State private var editor: StudentEditor?
    @State private var genderFilter: GenderFilter?
    @State private var allocationFilter: AllocationFilter?

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

    private func isOverallocated(_ student: Student) -> Bool {
        sessionCount(for: student) > student.sessionsDemand
    }

    private var underallocatedCount: Int {
        students.filter(isUnderallocated).count
    }

    private var overallocatedCount: Int {
        students.filter(isOverallocated).count
    }

    private var weeklyDemand: Int {
        students.reduce(0) { $0 + $1.sessionsDemand }
    }

    private var allocatedSessions: Int {
        sessionCountByStudent.values.reduce(0, +)
    }

    private func count(for filter: GenderFilter) -> Int {
        switch filter {
        case .male: return students.filter { $0.gender == "Male" }.count
        case .female: return students.filter { $0.gender == "Female" }.count
        }
    }

    private func count(for filter: AllocationFilter) -> Int {
        switch filter {
        case .underallocated: return underallocatedCount
        case .overallocated: return overallocatedCount
        }
    }

    private var filteredStudents: [Student] {
        students.filter { student in
            let matchesGender: Bool
            switch genderFilter {
            case .male:
                matchesGender = student.gender == "Male"
            case .female:
                matchesGender = student.gender == "Female"
            case nil:
                matchesGender = true
            }

            let matchesAllocation: Bool
            switch allocationFilter {
            case .underallocated:
                matchesAllocation = isUnderallocated(student)
            case .overallocated:
                matchesAllocation = isOverallocated(student)
            case nil:
                matchesAllocation = true
            }

            return matchesGender && matchesAllocation
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
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    ForEach(GenderFilter.allCases) { option in
                                        FilterChip(
                                            title: option.rawValue,
                                            count: count(for: option),
                                            isSelected: genderFilter == option
                                        ) {
                                            genderFilter = genderFilter == option ? nil : option
                                        }
                                    }
                                }

                                HStack(spacing: 8) {
                                    ForEach(AllocationFilter.allCases) { option in
                                        FilterChip(
                                            title: option.rawValue,
                                            count: count(for: option),
                                            isSelected: allocationFilter == option
                                        ) {
                                            allocationFilter = allocationFilter == option ? nil : option
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
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

private struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(badgeBackground))
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.radius)
                    .fill(isSelected ? Color.accentColor : AppStyle.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppStyle.radius)
                    .stroke(AppStyle.separator.opacity(isSelected ? 0 : 0.18), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }

    private var badgeBackground: Color {
        isSelected ? .white.opacity(0.22) : Color.accentColor.opacity(0.12)
    }
}

#Preview {
    StudentListView()
        .modelContainer(for: [Student.self, CoachingSession.self, CourtBooking.self], inMemory: true)
}
