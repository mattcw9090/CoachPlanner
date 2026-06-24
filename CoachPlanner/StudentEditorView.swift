import SwiftData
import SwiftUI

struct StudentEditor: Identifiable {
    let id = UUID()
    let student: Student?

    init(student: Student? = nil) {
        self.student = student
    }
}

struct StudentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let editor: StudentEditor

    @State private var name: String
    @State private var gender: Gender
    @State private var notes: String

    init(editor: StudentEditor) {
        self.editor = editor
        _name = State(initialValue: editor.student?.name ?? "")
        _gender = State(initialValue: editor.student?.gender ?? .male)
        _notes = State(initialValue: editor.student?.notes ?? "")
    }

    private var isEditing: Bool {
        editor.student != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Student Details") {
                    TextField("Name", text: $name)
                        .textContentType(.name)

                    Picker("Gender", selection: $gender) {
                        ForEach(Gender.allCases, id: \.self) { gender in
                            Text(gender.rawValue).tag(gender)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if isEditing {
                    Section {
                        Button("Delete Student", role: .destructive) {
                            deleteStudent()
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Student" : "New Student")
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
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
    }

    private var hasUnsavedChanges: Bool {
        name != (editor.student?.name ?? "") ||
            gender != (editor.student?.gender ?? .male) ||
            notes != (editor.student?.notes ?? "")
    }

    private func save() {
        if let student = editor.student {
            student.name = trimmedName
            student.gender = gender
            student.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let student = Student(
                name: trimmedName,
                gender: gender,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            modelContext.insert(student)
        }

        dismiss()
    }

    private func deleteStudent() {
        guard let student = editor.student else { return }
        modelContext.delete(student)
        dismiss()
    }
}
