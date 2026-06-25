import SwiftData
import SwiftUI
import UIKit

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
    @State private var gender: String
    @State private var contactPreference: ContactPreference
    @State private var contactDetail: String
    @State private var sessionsDemand: Int

    private let genderOptions = ["Male", "Female"]

    init(editor: StudentEditor) {
        self.editor = editor
        _name = State(initialValue: editor.student?.name ?? "")
        _gender = State(initialValue: editor.student?.gender ?? "")
        _contactPreference = State(initialValue: editor.student?.contactPreferenceValue ?? .instagram)
        _contactDetail = State(initialValue: editor.student?.contactDetail ?? "")
        _sessionsDemand = State(initialValue: editor.student?.sessionsDemand ?? 1)
    }

    private var isEditing: Bool {
        editor.student != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedContactDetail: String {
        contactDetail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isContactValid: Bool {
        !trimmedContactDetail.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Student Details") {
                    TextField("Name", text: $name)
                        .textContentType(.name)

                    Picker("Gender", selection: $gender) {
                        ForEach(genderOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper(value: $sessionsDemand, in: 0...7) {
                        HStack {
                            Text("Sessions per week")
                            Spacer()
                            Text("\(sessionsDemand)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Picker("Preferred Contact", selection: $contactPreference) {
                        ForEach(ContactPreference.allCases) { preference in
                            Label(preference.rawValue, systemImage: preference.iconName)
                                .tag(preference)
                        }
                    }

                    TextField(contactPreference.placeholder, text: $contactDetail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(keyboardType)
                        .textContentType(textContentType)
                } header: {
                    Text("Contact")
                } footer: {
                    if !isContactValid {
                        Text("\(contactPreference.detailLabel) is required for \(contactPreference.rawValue).")
                            .foregroundStyle(.red)
                    }
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
                    .disabled(trimmedName.isEmpty || gender.isEmpty || !isContactValid)
                }
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
    }

    private var hasUnsavedChanges: Bool {
        name != (editor.student?.name ?? "") ||
            gender != (editor.student?.gender ?? "") ||
            contactPreference != (editor.student?.contactPreferenceValue ?? .instagram) ||
            contactDetail != (editor.student?.contactDetail ?? "") ||
            sessionsDemand != (editor.student?.sessionsDemand ?? 1)
    }

    private var keyboardType: UIKeyboardType {
        switch contactPreference {
        case .instagram:
            return .twitter
        case .whatsApp, .sms:
            return .phonePad
        case .fbMessenger:
            return .URL
        }
    }

    private var textContentType: UITextContentType? {
        switch contactPreference {
        case .instagram:
            return .username
        case .whatsApp, .sms:
            return .telephoneNumber
        case .fbMessenger:
            return .URL
        }
    }

    private func save() {
        if let student = editor.student {
            student.name = trimmedName
            student.gender = gender
            student.contactPreference = contactPreference.rawValue
            student.contactDetail = trimmedContactDetail
            student.sessionsDemand = sessionsDemand
        } else {
            let student = Student(
                name: trimmedName,
                gender: gender,
                contactPreference: contactPreference,
                contactDetail: trimmedContactDetail,
                sessionsDemand: sessionsDemand
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
