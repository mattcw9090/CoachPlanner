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

private enum VisibilityFilter: String, CaseIterable, Identifiable {
    case active = "Active"
    case hidden = "Hidden"

    var id: String { rawValue }
}

struct StudentListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Student.name) private var students: [Student]
    @Query private var sessions: [CoachingSession]
    @Query private var hiddenWeeks: [StudentHiddenWeek]
    @AppStorage("weekStartTimestamp") private var weekStartTimestamp: Double = 0

    @State private var editor: StudentEditor?
    @State private var genderFilter: GenderFilter?
    @State private var allocationFilter: AllocationFilter?
    @State private var visibilityFilter: VisibilityFilter = .active

    private var studentSummary: StudentSummary {
        var counts: [PersistentIdentifier: Int] = [:]
        for session in sessionsForSelectedWeek {
            for student in session.students {
                counts[student.persistentModelID, default: 0] += 1
            }
        }
        let hiddenStudentIDs = hiddenStudentIDsForSelectedWeek

        var maleCount = 0
        var femaleCount = 0
        var underallocatedCount = 0
        var overallocatedCount = 0
        var activeCount = 0
        var hiddenCount = 0
        var weeklyDemand = 0
        var allocatedSessions = 0

        let filteredStudents = students.filter { student in
            let sessionCount = counts[student.persistentModelID] ?? 0
            let isUnderallocated = sessionCount < student.sessionsDemand
            let isOverallocated = sessionCount > student.sessionsDemand
            let isHidden = hiddenStudentIDs.contains(student.persistentModelID)

            if student.gender == "Male" {
                maleCount += 1
            } else if student.gender == "Female" {
                femaleCount += 1
            }

            if isHidden {
                hiddenCount += 1
            } else {
                activeCount += 1
                if isUnderallocated {
                    underallocatedCount += 1
                }
                if isOverallocated {
                    overallocatedCount += 1
                }
                weeklyDemand += student.sessionsDemand
                allocatedSessions += sessionCount
            }

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
            if isHidden {
                matchesAllocation = allocationFilter == nil
            } else {
                switch allocationFilter {
                case .underallocated:
                    matchesAllocation = isUnderallocated
                case .overallocated:
                    matchesAllocation = isOverallocated
                case nil:
                    matchesAllocation = true
                }
            }

            let matchesVisibility: Bool
            switch visibilityFilter {
            case .active:
                matchesVisibility = !isHidden
            case .hidden:
                matchesVisibility = isHidden
            }

            return matchesGender && matchesAllocation && matchesVisibility
        }

        return StudentSummary(
            sessionCountByStudent: counts,
            hiddenStudentIDs: hiddenStudentIDs,
            filteredStudents: filteredStudents,
            maleCount: maleCount,
            femaleCount: femaleCount,
            underallocatedCount: underallocatedCount,
            overallocatedCount: overallocatedCount,
            activeCount: activeCount,
            hiddenCount: hiddenCount,
            weeklyDemand: weeklyDemand,
            allocatedSessions: allocatedSessions
        )
    }

    private var selectedWeekStart: Date {
        if weekStartTimestamp == 0 {
            return Self.monday(of: .now)
        }
        return Self.monday(of: Date(timeIntervalSince1970: weekStartTimestamp))
    }

    private var sessionsForSelectedWeek: [CoachingSession] {
        sessions.filter { session in
            let sessionWeekStart = session.weekStart ?? selectedWeekStart
            return Calendar.current.isDate(Self.monday(of: sessionWeekStart), inSameDayAs: selectedWeekStart)
        }
    }

    private var hiddenStudentIDsForSelectedWeek: Set<PersistentIdentifier> {
        Set(
            hiddenWeeks.compactMap { hiddenWeek in
                guard Calendar.current.isDate(Self.monday(of: hiddenWeek.weekStart), inSameDayAs: selectedWeekStart),
                      let student = hiddenWeek.student else {
                    return nil
                }
                return student.persistentModelID
            }
        )
    }

    private static func monday(of date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? date
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
                                    title: "Active",
                                    value: "\(summary.activeCount)",
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
                                    title: "Hidden",
                                    value: "\(summary.hiddenCount)",
                                    systemImage: "eye.slash.fill",
                                    tint: .secondary
                                )
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)

                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    ForEach(VisibilityFilter.allCases) { option in
                                        FilterChip(
                                            title: option.rawValue,
                                            count: summary.count(for: option),
                                            isSelected: visibilityFilter == option
                                        ) {
                                            visibilityFilter = option
                                            if option == .hidden {
                                                allocationFilter = nil
                                            }
                                        }
                                    }
                                }

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
                                            demand: student.sessionsDemand,
                                            isHidden: summary.isHidden(student)
                                        )
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        toggleHidden(student, isCurrentlyHidden: summary.isHidden(student))
                                        if !summary.isHidden(student) {
                                            allocationFilter = nil
                                        }
                                    } label: {
                                        Label(summary.isHidden(student) ? "Unhide" : "Hide", systemImage: summary.isHidden(student) ? "eye.fill" : "eye.slash.fill")
                                    }
                                    .tint(summary.isHidden(student) ? .blue : .gray)
                                }
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
            .onAppear {
                migrateGlobalHiddenStudentsIfNeeded()
            }
        }
    }

    private func toggleHidden(_ student: Student, isCurrentlyHidden: Bool) {
        if isCurrentlyHidden {
            for hiddenWeek in hiddenWeeks where hiddenWeek.student?.persistentModelID == student.persistentModelID && Calendar.current.isDate(Self.monday(of: hiddenWeek.weekStart), inSameDayAs: selectedWeekStart) {
                modelContext.delete(hiddenWeek)
            }
        } else {
            let hiddenWeek = StudentHiddenWeek(student: student, weekStart: selectedWeekStart)
            modelContext.insert(hiddenWeek)
        }
    }

    private func migrateGlobalHiddenStudentsIfNeeded() {
        let hiddenIDs = hiddenStudentIDsForSelectedWeek
        for student in students where student.isHidden {
            if !hiddenIDs.contains(student.persistentModelID) {
                modelContext.insert(StudentHiddenWeek(student: student, weekStart: selectedWeekStart))
            }
            student.isHidden = false
        }
    }

    private func deleteStudents(at offsets: IndexSet, from filteredStudents: [Student]) {
        let toDelete = offsets.map { filteredStudents[$0] }
        for student in toDelete {
            for hiddenWeek in hiddenWeeks where hiddenWeek.student?.persistentModelID == student.persistentModelID {
                modelContext.delete(hiddenWeek)
            }
            modelContext.delete(student)
        }
    }
}

private struct StudentSummary {
    let sessionCountByStudent: [PersistentIdentifier: Int]
    let hiddenStudentIDs: Set<PersistentIdentifier>
    let filteredStudents: [Student]
    let maleCount: Int
    let femaleCount: Int
    let underallocatedCount: Int
    let overallocatedCount: Int
    let activeCount: Int
    let hiddenCount: Int
    let weeklyDemand: Int
    let allocatedSessions: Int

    func sessionCount(for student: Student) -> Int {
        sessionCountByStudent[student.persistentModelID] ?? 0
    }

    func isHidden(_ student: Student) -> Bool {
        hiddenStudentIDs.contains(student.persistentModelID)
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

    func count(for filter: VisibilityFilter) -> Int {
        switch filter {
        case .active: return activeCount
        case .hidden: return hiddenCount
        }
    }
}

private struct StudentRow: View {
    let student: Student
    let sessionCount: Int
    let demand: Int
    let isHidden: Bool

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
                HStack(spacing: 6) {
                    Text(student.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(isHidden ? .secondary : .primary)

                    if isHidden {
                        Text("Hidden")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }

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
        .modelContainer(for: [Student.self, StudentHiddenWeek.self, Outsider.self, CoachingSession.self, CourtBooking.self, SocialSession.self, SocialHiddenPerson.self, SocialAttendance.self], inMemory: true)
}
