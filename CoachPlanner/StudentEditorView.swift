import ContactsUI
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
    @State private var isContactPickerPresented = false

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
        switch contactPreference {
        case .instagram:
            return !Self.instagramHandle(from: contactDetail).isEmpty
        case .whatsApp, .sms:
            return !Self.australianLocalDigits(from: contactDetail).isEmpty
        case .fbMessenger:
            return !Self.facebookProfilePath(from: contactDetail).isEmpty
        }
    }

    private var usesPhoneContactPicker: Bool {
        contactPreference == .whatsApp || contactPreference == .sms
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Student Details") {
                    TextField("Name", text: nameBinding)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)

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

                    HStack {
                        if contactPreference == .instagram {
                            Text("@")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)

                            TextField("username", text: contactDetailBinding)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(keyboardType)
                                .textContentType(textContentType)
                        } else if usesPhoneContactPicker {
                            Text("+61")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)

                            TextField("412 345 678", text: contactDetailBinding)
                                .keyboardType(keyboardType)
                                .textContentType(textContentType)
                        } else if contactPreference == .fbMessenger {
                            Text("https://facebook.com/")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityHidden(true)

                            TextField("username", text: contactDetailBinding)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(keyboardType)
                                .textContentType(textContentType)
                        } else {
                            TextField(contactPreference.placeholder, text: contactDetailBinding)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(keyboardType)
                                .textContentType(textContentType)
                        }

                        if usesPhoneContactPicker {
                            Button {
                                isContactPickerPresented = true
                            } label: {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Pick from Contacts")
                        }
                    }
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
            .onChange(of: contactPreference) { _, _ in
                normalizeContactDetailForPreference()
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .background(
            PhoneContactPickerPresenter(
                isPresented: $isContactPickerPresented
            ) { phone in
                contactDetail = Self.formattedAustralianPhoneNumber(phone)
            }
        )
    }

    private var hasUnsavedChanges: Bool {
        name != (editor.student?.name ?? "") ||
            gender != (editor.student?.gender ?? "") ||
            contactPreference != (editor.student?.contactPreferenceValue ?? .instagram) ||
            contactDetail != (editor.student?.contactDetail ?? "") ||
            sessionsDemand != (editor.student?.sessionsDemand ?? 1)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { name },
            set: { name = Self.capitalizedWords(newValue: $0) }
        )
    }

    private var contactDetailBinding: Binding<String> {
        Binding(
            get: {
                if contactPreference == .instagram {
                    return Self.instagramHandle(from: contactDetail)
                } else if usesPhoneContactPicker {
                    return Self.formattedAustralianLocalNumber(contactDetail)
                } else if contactPreference == .fbMessenger {
                    return Self.facebookProfilePath(from: contactDetail)
                }
                return contactDetail
            },
            set: { newValue in
                if contactPreference == .instagram {
                    contactDetail = Self.formattedInstagramHandle(newValue)
                } else if usesPhoneContactPicker {
                    contactDetail = Self.formattedAustralianPhoneNumber(newValue)
                } else if contactPreference == .fbMessenger {
                    contactDetail = Self.formattedFacebookProfile(newValue)
                } else {
                    contactDetail = newValue
                }
            }
        )
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

    private func normalizeContactDetailForPreference() {
        if contactPreference == .instagram {
            contactDetail = Self.formattedInstagramHandle(contactDetail)
        } else if usesPhoneContactPicker {
            contactDetail = Self.formattedAustralianPhoneNumber(contactDetail)
        } else if contactPreference == .fbMessenger {
            contactDetail = Self.formattedFacebookProfile(contactDetail)
        } else if contactDetail == "+61" || contactDetail == "+61 " {
            contactDetail = ""
        }
    }

    private static func capitalizedWords(newValue: String) -> String {
        var shouldCapitalizeNext = true
        return String(newValue.map { character in
            if character.isWhitespace {
                shouldCapitalizeNext = true
                return character
            }

            if shouldCapitalizeNext {
                shouldCapitalizeNext = false
                return Character(character.uppercased())
            }

            return character
        })
    }

    private static func instagramHandle(from value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    private static func formattedInstagramHandle(_ value: String) -> String {
        let handle = instagramHandle(from: value)
        return handle.isEmpty ? "" : "@\(handle)"
    }

    private static func facebookProfilePath(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let host = url.host,
           host.localizedCaseInsensitiveContains("facebook.com") {
            return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        return trimmed
            .replacingOccurrences(of: "https://facebook.com/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "http://facebook.com/", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formattedFacebookProfile(_ value: String) -> String {
        let profile = facebookProfilePath(from: value)
        return profile.isEmpty ? "" : "https://facebook.com/\(profile)"
    }

    private static func formattedAustralianPhoneNumber(_ value: String) -> String {
        let localDigits = australianLocalDigits(from: value)
        guard !localDigits.isEmpty else { return "" }
        return "+61" + localDigits
    }

    private static func formattedAustralianLocalNumber(_ value: String) -> String {
        groupedAustralianLocalDigits(australianLocalDigits(from: value))
    }

    private static func australianLocalDigits(from value: String) -> String {
        let digits = value.filter(\.isNumber)

        var localDigits: String
        if digits.hasPrefix("61") {
            localDigits = String(digits.dropFirst(2))
            if localDigits.hasPrefix("0") {
                localDigits.removeFirst()
            }
        } else if digits.hasPrefix("0") {
            localDigits = String(digits.dropFirst())
        } else {
            localDigits = digits
        }

        return String(localDigits.prefix(9))
    }

    private static func groupedAustralianLocalDigits(_ localDigits: String) -> String {
        guard !localDigits.isEmpty else { return "" }
        var groups: [String] = []
        groups.append(String(localDigits.prefix(3)))

        if localDigits.count > 3 {
            let start = localDigits.index(localDigits.startIndex, offsetBy: 3)
            let end = localDigits.index(start, offsetBy: min(3, localDigits.distance(from: start, to: localDigits.endIndex)))
            groups.append(String(localDigits[start..<end]))
        }

        if localDigits.count > 6 {
            let start = localDigits.index(localDigits.startIndex, offsetBy: 6)
            groups.append(String(localDigits[start...]))
        }

        return groups.joined(separator: " ")
    }

    private func save() {
        let savedContactDetail: String
        switch contactPreference {
        case .instagram:
            savedContactDetail = Self.formattedInstagramHandle(contactDetail)
        case .whatsApp, .sms:
            savedContactDetail = Self.formattedAustralianPhoneNumber(contactDetail)
        case .fbMessenger:
            savedContactDetail = Self.formattedFacebookProfile(contactDetail)
        }

        if let student = editor.student {
            student.name = trimmedName
            student.gender = gender
            student.contactPreference = contactPreference.rawValue
            student.contactDetail = savedContactDetail
            student.sessionsDemand = sessionsDemand
        } else {
            let student = Student(
                name: trimmedName,
                gender: gender,
                contactPreference: contactPreference,
                contactDetail: savedContactDetail,
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

private struct PhoneContactPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPick: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.parent = self

        guard isPresented else {
            if let picker = context.coordinator.presentedPicker {
                picker.dismiss(animated: true)
                context.coordinator.presentedPicker = nil
            }
            return
        }

        guard context.coordinator.presentedPicker == nil,
              uiViewController.presentedViewController == nil else { return }

        let picker = CNContactPickerViewController()
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        picker.predicateForSelectionOfContact = NSPredicate(format: "phoneNumbers.@count == 1")
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == 'phoneNumbers'")
        picker.delegate = context.coordinator

        context.coordinator.presentedPicker = picker
        uiViewController.present(picker, animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: PhoneContactPickerPresenter
        weak var presentedPicker: CNContactPickerViewController?

        init(parent: PhoneContactPickerPresenter) {
            self.parent = parent
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            if let number = contact.phoneNumbers.first?.value.stringValue {
                parent.onPick(number)
            }
            dismissPicker()
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            if let phone = contactProperty.value as? CNPhoneNumber {
                parent.onPick(phone.stringValue)
            }
            dismissPicker()
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            dismissPicker()
        }

        private func dismissPicker() {
            presentedPicker = nil
            parent.isPresented = false
        }
    }
}
