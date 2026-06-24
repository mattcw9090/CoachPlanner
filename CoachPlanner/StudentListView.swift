import SwiftData
import SwiftUI

struct StudentListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Student.name) private var students: [Student]

    @State private var editor: StudentEditor?

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
                        ForEach(students) { student in
                            Button {
                                editor = StudentEditor(student: student)
                            } label: {
                                StudentRow(student: student)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteStudents)
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
        for index in offsets {
            modelContext.delete(students[index])
        }
    }
}

private struct StudentRow: View {
    let student: Student

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: student.gender == .male ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.title)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(student.name)
                    .font(.headline)

                Text(student.gender.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !student.notes.isEmpty {
                    Text(student.notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
    StudentListView()
        .modelContainer(for: Student.self, inMemory: true)
}
