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

    private var studentSummary: StudentSummary {
        var counts: [PersistentIdentifier: Int] = [:]
        for session in sessions {
            for student in session.students {
                counts[student.persistentModelID, default: 0] += 1
            }
        }

        var maleCount = 0
        var femaleCount = 0
        var underallocatedCount = 0
        var overallocatedCount = 0
        var weeklyDemand = 0

        let filteredStudents = students.filter { student in
            let sessionCount = counts[student.persistentModelID] ?? 0
            let isUnderallocated = sessionCount < student.sessionsDemand
            let isOverallocated = sessionCount > student.sessionsDemand

            if student.gender == "Male" {
                maleCount += 1
            } else if student.gender == "Female" {
                femaleCount += 1
            }
            if isUnderallocated {
                underallocatedCount += 1
            }
            if isOverallocated {
                overallocatedCount += 1
            }
            weeklyDemand += student.sessionsDemand

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
                matchesAllocation = isUnderallocated
            case .overallocated:
                matchesAllocation = isOverallocated
            case nil:
                matchesAllocation = true
            }

            return matchesGender && matchesAllocation
        }

        return StudentSummary(
            sessionCountByStudent: counts,
            filteredStudents: filteredStudents,
            maleCount: maleCount,
            femaleCount: femaleCount,
            underallocatedCount: underallocatedCount,
            overallocatedCount: overallocatedCount,
            weeklyDemand: weeklyDemand,
            allocatedSessions: counts.values.reduce(0, +)
        )
    }

    var body: some View {
        let summary = studentSummary

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
                                    value: "\(summary.underallocatedCount)",
                                    systemImage: "exclamationmark.circle.fill",
                                    tint: summary.underallocatedCount == 0 ? .green : .red
                                )
                                MetricTile(
                                    title: "Booked",
                                    value: "\(summary.allocatedSessions)/\(summary.weeklyDemand)",
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
                                            count: summary.count(for: option),
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
                                            count: summary.count(for: option),
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
                            ForEach(summary.filteredStudents) { student in
                                Button {
                                    editor = StudentEditor(student: student)
                                } label: {
                                    StudentRow(
                                        student: student,
                                        sessionCount: summary.sessionCount(for: student),
                                        demand: student.sessionsDemand
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                deleteStudents(at: offsets, from: summary.filteredStudents)
                            }
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

    private func deleteStudents(at offsets: IndexSet, from filteredStudents: [Student]) {
        let toDelete = offsets.map { filteredStudents[$0] }
        for student in toDelete {
            modelContext.delete(student)
        }
    }
}

private struct StudentSummary {
    let sessionCountByStudent: [PersistentIdentifier: Int]
    let filteredStudents: [Student]
    let maleCount: Int
    let femaleCount: Int
    let underallocatedCount: Int
    let overallocatedCount: Int
    let weeklyDemand: Int
    let allocatedSessions: Int

    func sessionCount(for student: Student) -> Int {
        sessionCountByStudent[student.persistentModelID] ?? 0
    }

    func count(for filter: GenderFilter) -> Int {
        switch filter {
        case .male: return maleCount
        case .female: return femaleCount
        }
    }

    func count(for filter: AllocationFilter) -> Int {
        switch filter {
        case .underallocated: return underallocatedCount
        case .overallocated: return overallocatedCount
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
        .modelContainer(for: [Student.self, Outsider.self, CoachingSession.self, CourtBooking.self, SocialSession.self, SocialAttendance.self], inMemory: true)
}
