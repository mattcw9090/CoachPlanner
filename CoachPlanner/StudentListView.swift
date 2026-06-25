import SwiftData
import SwiftUI

private enum GenderFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case male = "Male"
    case female = "Female"

    var id: String { rawValue }
}

struct StudentListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Student.name) private var students: [Student]

    @State private var editor: StudentEditor?
    @State private var filter: GenderFilter = .all

    private var femaleCount: Int {
        students.filter { $0.gender == "Female" }.count
    }

    private var maleCount: Int {
        students.filter { $0.gender == "Male" }.count
    }

    private func count(for filter: GenderFilter) -> Int {
        switch filter {
        case .all: return students.count
        case .female: return femaleCount
        case .male: return maleCount
        }
    }

    private var filteredStudents: [Student] {
        switch filter {
        case .all: return students
        case .female: return students.filter { $0.gender == "Female" }
        case .male: return students.filter { $0.gender == "Male" }
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
                            Picker("Filter", selection: $filter) {
                                ForEach(GenderFilter.allCases) { option in
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
                                    StudentRow(student: student)
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

    private var iconColor: Color {
        switch student.gender {
        case "Female": return .pink
        case "Male": return .blue
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(iconColor)

            Text(student.name)
                .font(.headline)

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
    StudentListView()
        .modelContainer(for: Student.self, inMemory: true)
}
