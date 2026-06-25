import SwiftData
import SwiftUI
import UIKit

struct SessionEditor: Identifiable {
    let id = UUID()
    let session: CoachingSession?
    let preselectedDay: Weekday?
    let preselectedStartTime: Date?
    let preselectedEndTime: Date?
    let weekStart: Date?

    init(
        session: CoachingSession? = nil,
        preselectedDay: Weekday? = nil,
        preselectedStartTime: Date? = nil,
        preselectedEndTime: Date? = nil,
        weekStart: Date? = nil
    ) {
        self.session = session
        self.preselectedDay = preselectedDay
        self.preselectedStartTime = preselectedStartTime
        self.preselectedEndTime = preselectedEndTime
        self.weekStart = weekStart
    }
}

struct SessionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @Query(sort: \Student.name) private var students: [Student]
    @Query private var existingSessions: [CoachingSession]

    let editor: SessionEditor

    @State private var dayOfWeek: Weekday
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var venue: Venue
    @State private var status: SessionStatus
    @State private var isCourtBooked: Bool
    @State private var courtNumber: String
    @State private var sessionFeeText: String
    @State private var selectedStudentIDs: Set<PersistentIdentifier>
    @State private var studentSearch: String = ""
    @State private var hasUserAdjustedStart: Bool = false
    @State private var hasUserAdjustedEnd: Bool = false
    @State private var hasUserAdjustedVenue: Bool = false
    @State private var contactNotice: ContactNotice?
    @FocusState private var isSearchFocused: Bool

    init(editor: SessionEditor) {
        self.editor = editor
        let initialDay = editor.session?.weekday ?? editor.preselectedDay ?? .monday
        _dayOfWeek = State(initialValue: initialDay)

        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: .now) ?? .now
        let defaultEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now

        _startTime = State(initialValue: editor.session?.startTime ?? editor.preselectedStartTime ?? defaultStart)
        _endTime = State(initialValue: editor.session?.endTime ?? editor.preselectedEndTime ?? defaultEnd)
        _venue = State(initialValue: editor.session?.venueValue ?? .pbaMalaga)
        _status = State(initialValue: editor.session?.statusValue ?? .unscheduled)
        let existingCourtNumber = editor.session?.courtNumber ?? ""
        _isCourtBooked = State(
            initialValue: !existingCourtNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        _courtNumber = State(initialValue: existingCourtNumber)
        _sessionFeeText = State(initialValue: Self.feeText(for: editor.session?.sessionFee ?? 0))
        _selectedStudentIDs = State(
            initialValue: Set(editor.session?.students.map(\.persistentModelID) ?? [])
        )
        _hasUserAdjustedStart = State(initialValue: editor.preselectedStartTime != nil)
        _hasUserAdjustedEnd = State(initialValue: editor.preselectedEndTime != nil)
    }

    private var isEditing: Bool {
        editor.session != nil
    }

    private var isTimeRangeValid: Bool {
        minutes(of: endTime) > minutes(of: startTime)
    }

    private var trimmedCourtNumber: String {
        courtNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCourtValid: Bool {
        !isCourtBooked || !trimmedCourtNumber.isEmpty
    }

    private var sessionFeeValue: Double {
        Double(sessionFeeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private var isSessionFeeValid: Bool {
        guard let value = Double(sessionFeeText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return value > 0
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
        isTimeRangeValid &&
            overlappingSession == nil &&
            !selectedStudentIDs.isEmpty &&
            isCourtValid &&
            isSessionFeeValid
    }

    private var messageWeekStart: Date {
        editor.weekStart ?? SessionListView.monday(of: .now)
    }

    private var selectedStudentsList: [Student] {
        students.filter { selectedStudentIDs.contains($0.persistentModelID) }
    }

    private var filteredStudentMatches: [Student] {
        let trimmed = studentSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let unselected = students.filter { !selectedStudentIDs.contains($0.persistentModelID) }
        guard !trimmed.isEmpty else { return unselected }
        return unselected.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if students.isEmpty {
                        Text("Add students first before assigning them to sessions.")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search students", text: $studentSearch)
                                .focused($isSearchFocused)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !studentSearch.isEmpty {
                                Button {
                                    studentSearch = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        if !studentSearch.isEmpty {
                            if filteredStudentMatches.isEmpty {
                                Text("No matches")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(filteredStudentMatches) { student in
                                    Button {
                                        selectedStudentIDs.insert(student.persistentModelID)
                                        studentSearch = ""
                                    } label: {
                                        HStack {
                                            Image(systemName: "person.crop.circle.fill")
                                                .foregroundStyle(iconColor(for: student))
                                            Text(student.name)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: "plus.circle.fill")
                                                .foregroundStyle(.tint)
                                        }
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

                if !selectedStudentsList.isEmpty {
                    Section("Selected (\(selectedStudentsList.count))") {
                        StudentChipFlow(spacing: 6) {
                            ForEach(selectedStudentsList) { student in
                                StudentChip(
                                    name: student.name,
                                    color: iconColor(for: student)
                                ) {
                                    selectedStudentIDs.remove(student.persistentModelID)
                                }
                            }
                        }
                    }
                }

                if isEditing && !selectedStudentsList.isEmpty {
                    Section {
                        ForEach(selectedStudentsList) { student in
                            Button {
                                contact(student)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: student.contactPreferenceValue.iconName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.tint)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Ask \(student.name)")
                                            .foregroundStyle(.primary)
                                        Text("\(student.contactPreferenceValue.rawValue) · all sessions")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "paperplane.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Contact")
                    } footer: {
                        Text("Opens the student's preferred contact app with one availability message covering every session assigned to them.")
                    }
                }

                Section {
                    Picker("Venue", selection: Binding(
                        get: { venue },
                        set: { newValue in
                            venue = newValue
                            hasUserAdjustedVenue = true
                        }
                    )) {
                        ForEach(Venue.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }

                    Picker("Status", selection: $status) {
                        ForEach(SessionStatus.allCases) { option in
                            HStack {
                                Image(systemName: option.iconName)
                                    .foregroundStyle(option.color)
                                Text(option.rawValue)
                            }
                            .tag(option)
                        }
                    }
                } header: {
                    Text("Session Details")
                }

                Section {
                    Toggle("Court Booked", isOn: $isCourtBooked)

                    if isCourtBooked {
                        TextField("Court number", text: $courtNumber)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                    }

                    HStack {
                        Text("Session Fee")
                        Spacer()
                        HStack(spacing: 4) {
                            Text(currencySymbol)
                                .foregroundStyle(.secondary)
                            TextField("0.00", text: $sessionFeeText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 96)
                        }
                    }
                } header: {
                    Text("Booking & Fee")
                } footer: {
                    if isCourtBooked && trimmedCourtNumber.isEmpty {
                        Text("Court number is required when a court has been booked.")
                            .foregroundStyle(.red)
                    } else if !isSessionFeeValid {
                        Text("Session fee is required and must be greater than zero.")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Day of Week", selection: $dayOfWeek) {
                        ForEach(Weekday.allCases) { day in
                            Text(day.name).tag(day)
                        }
                    }

                    LabeledContent("Start Time") {
                        HalfHourTimePicker(selection: Binding(
                            get: { startTime },
                            set: { newValue in
                                startTime = newValue
                                hasUserAdjustedStart = true
                                if !hasUserAdjustedEnd,
                                   let autoEnd = Calendar.current.date(byAdding: .hour, value: 1, to: newValue) {
                                    endTime = autoEnd
                                }
                            }
                        ))
                    }

                    LabeledContent("End Time") {
                        HalfHourTimePicker(selection: Binding(
                            get: { endTime },
                            set: { newValue in
                                endTime = newValue
                                hasUserAdjustedEnd = true
                            }
                        ))
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    if !isTimeRangeValid {
                        Text("End time must be after start time.")
                            .foregroundStyle(.red)
                    } else if let overlap = overlappingSession {
                        Text("Overlaps with \(overlap.weekday.name) \(timeRangeText(for: overlap)) at \(overlap.venue).")
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
            .onAppear {
                applyAutoFillIfNeeded()
            }
            .onChange(of: dayOfWeek) { _, _ in
                applyAutoFillIfNeeded()
            }
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
            .alert(item: $contactNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func minutes(of date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private func applyAutoFillIfNeeded() {
        guard !isEditing,
              !hasUserAdjustedStart,
              !hasUserAdjustedEnd,
              !hasUserAdjustedVenue else { return }

        let calendar = Calendar.current
        let sameDaySessions = existingSessions.filter {
            $0.dayOfWeek == dayOfWeek.rawValue
        }

        let startMinutes: Int
        if let latest = sameDaySessions.max(by: { minutes(of: $0.endTime) < minutes(of: $1.endTime) }) {
            if let latestVenue = Venue(rawValue: latest.venue) {
                venue = latestVenue
            }
            startMinutes = minutes(of: latest.endTime)
        } else {
            startMinutes = 17 * 60
        }

        let clampedStart = min(startMinutes, 23 * 60)
        let clampedEnd = min(clampedStart + 60, 24 * 60 - 1)

        if let newStart = calendar.date(bySettingHour: clampedStart / 60, minute: clampedStart % 60, second: 0, of: .now),
           let newEnd = calendar.date(bySettingHour: clampedEnd / 60, minute: clampedEnd % 60, second: 0, of: .now) {
            startTime = newStart
            endTime = newEnd
        }
    }

    private func timeRangeText(for session: CoachingSession) -> String {
        let formatter = Date.FormatStyle.dateTime.hour().minute()
        return "\(session.startTime.formatted(formatter))–\(session.endTime.formatted(formatter))"
    }

    private var currencySymbol: String {
        Locale.current.currencySymbol ?? "$"
    }

    private static func feeText(for amount: Double) -> String {
        amount == 0 ? "" : String(format: "%.2f", amount)
    }

    private func iconColor(for student: Student) -> Color {
        AppStyle.genderColor(for: student.gender)
    }

    private func contact(_ student: Student) {
        let message = availabilityMessage(for: student)
        let preference = student.contactPreferenceValue

        if preference.requiresClipboardMessage {
            UIPasteboard.general.string = message
            contactNotice = ContactNotice(
                title: "Message Copied",
                message: "Paste the copied availability message into \(preference.rawValue)."
            )
        }

        guard let url = contactURL(for: student, message: message) else {
            contactNotice = ContactNotice(
                title: "Contact Unavailable",
                message: "The contact detail for \(student.name) does not look usable."
            )
            return
        }

        openURL(url)
    }

    private func availabilityMessage(for student: Student) -> String {
        let sessionLines = consolidatedSessions(for: student)
            .map { "- \($0.dateText), \($0.day.name), \($0.timeRange) at \($0.venue)" }
            .joined(separator: "\n")

        guard !sessionLines.isEmpty else {
            return "Hi \(student.name), are you available to train?"
        }

        return """
        Hi \(student.name), are you available for these training sessions?

        \(sessionLines)
        """
    }

    private func consolidatedSessions(for student: Student) -> [ContactSessionSummary] {
        let editingID = editor.session?.persistentModelID
        let currentStudentIDs = Set(selectedStudentsList.map(\.persistentModelID))

        var summaries = existingSessions.compactMap { session -> ContactSessionSummary? in
            guard session.persistentModelID != editingID,
                  session.students.contains(where: { $0.persistentModelID == student.persistentModelID }) else {
                return nil
            }
            return ContactSessionSummary(session: session, weekStart: messageWeekStart)
        }

        if currentStudentIDs.contains(student.persistentModelID) {
            summaries.append(
                ContactSessionSummary(
                    day: dayOfWeek,
                    startTime: startTime,
                    endTime: endTime,
                    venue: venue.rawValue,
                    weekStart: messageWeekStart
                )
            )
        }

        return summaries.sorted {
            if $0.day.rawValue == $1.day.rawValue {
                return minutes(of: $0.startTime) < minutes(of: $1.startTime)
            }
            return $0.day.rawValue < $1.day.rawValue
        }
    }

    private func contactURL(for student: Student, message: String) -> URL? {
        let detail = student.contactDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedMessage = percentEncodedMessage(message)

        switch student.contactPreferenceValue {
        case .instagram:
            let handle = detail
                .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !handle.isEmpty else { return nil }
            return URL(string: "https://ig.me/m/\(handle)")
        case .whatsApp:
            let phone = phoneDigits(from: detail)
            guard !phone.isEmpty else { return nil }
            return URL(string: "https://wa.me/\(phone)?text=\(encodedMessage)")
        case .fbMessenger:
            if let url = URL(string: detail), url.scheme != nil {
                return url
            }
            let profile = detail.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !profile.isEmpty else { return nil }
            return URL(string: "https://m.me/\(profile)")
        case .sms:
            let phone = smsPhoneNumber(from: detail)
            guard !phone.isEmpty else { return nil }
            return URL(string: "sms:\(phone)&body=\(encodedMessage)")
        }
    }

    private func percentEncodedMessage(_ message: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return message.addingPercentEncoding(withAllowedCharacters: allowed) ?? message
    }

    private func phoneDigits(from value: String) -> String {
        value.filter(\.isNumber)
    }

    private func smsPhoneNumber(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.hasPrefix("+") ? "+" : ""
        return prefix + trimmed.filter(\.isNumber)
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
            session.status = status.rawValue
            session.courtNumber = isCourtBooked ? trimmedCourtNumber : ""
            session.sessionFee = sessionFeeValue
            session.students = selectedStudents
        } else {
            let session = CoachingSession(
                dayOfWeek: dayOfWeek,
                startTime: startTime,
                endTime: endTime,
                venue: venue,
                status: status,
                courtNumber: isCourtBooked ? trimmedCourtNumber : "",
                sessionFee: sessionFeeValue,
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

private struct ContactNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct ContactSessionSummary {
    let day: Weekday
    let startTime: Date
    let endTime: Date
    let venue: String
    let weekStart: Date

    init(session: CoachingSession, weekStart: Date) {
        day = session.weekday
        startTime = session.startTime
        endTime = session.endTime
        venue = session.venue
        self.weekStart = weekStart
    }

    init(day: Weekday, startTime: Date, endTime: Date, venue: String, weekStart: Date) {
        self.day = day
        self.startTime = startTime
        self.endTime = endTime
        self.venue = venue
        self.weekStart = weekStart
    }

    var timeRange: String {
        Self.compactTimeRange(from: startTime, to: endTime)
    }

    var dateText: String {
        let date = Calendar.current.date(
            byAdding: .day,
            value: day.rawValue - 1,
            to: weekStart
        ) ?? weekStart
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private static func compactTimeRange(from startTime: Date, to endTime: Date) -> String {
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)

        let startHour = startComponents.hour ?? 0
        let startMinute = startComponents.minute ?? 0
        let endHour = endComponents.hour ?? 0
        let endMinute = endComponents.minute ?? 0
        let startPeriod = startHour < 12 ? "am" : "pm"
        let endPeriod = endHour < 12 ? "am" : "pm"

        let includeStartPeriod = startPeriod != endPeriod
        let start = compactTime(hour: startHour, minute: startMinute, period: startPeriod, includePeriod: includeStartPeriod)
        let end = compactTime(hour: endHour, minute: endMinute, period: endPeriod, includePeriod: true)
        return "\(start)-\(end)"
    }

    private static func compactTime(hour: Int, minute: Int, period: String, includePeriod: Bool) -> String {
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let minuteText = minute == 0 ? "" : ".\(String(format: "%02d", minute))"
        let periodText = includePeriod ? period : ""
        return "\(displayHour)\(minuteText)\(periodText)"
    }
}

private extension ContactPreference {
    var requiresClipboardMessage: Bool {
        switch self {
        case .instagram, .fbMessenger:
            return true
        case .whatsApp, .sms:
            return false
        }
    }
}

private struct HalfHourTimePicker: View {
    @Binding var selection: Date

    private var minutesBinding: Binding<Int> {
        Binding(
            get: {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: selection)
                let raw = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                return (raw / 30) * 30
            },
            set: { newMinutes in
                let calendar = Calendar.current
                if let newDate = calendar.date(
                    bySettingHour: newMinutes / 60,
                    minute: newMinutes % 60,
                    second: 0,
                    of: selection
                ) {
                    selection = newDate
                }
            }
        )
    }

    var body: some View {
        Picker("", selection: minutesBinding) {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { totalMinutes in
                Text(label(for: totalMinutes)).tag(totalMinutes)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func label(for totalMinutes: Int) -> String {
        let hour = totalMinutes / 60
        let minute = totalMinutes % 60
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour().minute())
    }
}

private struct StudentChip: View {
    let name: String
    let color: Color
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(color.opacity(0.15))
        )
    }
}

private struct StudentChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRowWidth + size.width > maxWidth && currentRowWidth > 0 {
                totalHeight += currentRowHeight + spacing
                currentRowWidth = size.width + spacing
                currentRowHeight = size.height
            } else {
                currentRowWidth += size.width + spacing
                currentRowHeight = max(currentRowHeight, size.height)
            }
        }
        totalHeight += currentRowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : currentRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += currentRowHeight + spacing
                currentRowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}
