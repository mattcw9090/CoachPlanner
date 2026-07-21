import SwiftData
import SwiftUI
import UIKit

struct SocialSessionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\SocialSession.weekStart),
            SortDescriptor(\SocialSession.dayOfWeek),
            SortDescriptor(\SocialSession.startTime)
        ]
    ) private var socialSessions: [SocialSession]
    @AppStorage("socialsWeekStartTimestamp") private var socialsWeekStartTimestamp: Double = 0
    @AppStorage("weekStartTimestamp") private var sessionsWeekStartTimestamp: Double = 0
    @State private var editor: SocialSessionEditor?
    @State private var copyNotice: SocialCopyNotice?

    private var weekStart: Date {
        if socialsWeekStartTimestamp == 0 {
            return Self.monday(of: .now)
        }
        return Date(timeIntervalSince1970: socialsWeekStartTimestamp)
    }

    private var weekEnd: Date {
        Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
    }

    private var weekRangeText: String {
        let formatter = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return "\(weekStart.formatted(formatter)) - \(weekEnd.formatted(formatter))"
    }

    private var sessionsForWeek: [SocialSession] {
        socialSessions.filter { Calendar.current.isDate($0.weekStart, inSameDayAs: weekStart) }
    }

    private var totalStudents: Int {
        sessionsForWeek.reduce(0) { $0 + attendanceCount(for: $1) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Socials Week")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(weekRangeText)
                                    .font(.title3.weight(.semibold))
                            }

                            Spacer()

                            HStack(spacing: 8) {
                                Button {
                                    moveWeek(by: -1)
                                } label: {
                                    Image(systemName: "chevron.left")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    moveWeek(by: 1)
                                } label: {
                                    Image(systemName: "chevron.right")
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        HStack(spacing: 10) {
                            MetricTile(
                                title: "Socials",
                                value: "\(sessionsForWeek.count)",
                                systemImage: "figure.badminton",
                                tint: .purple
                            )
                            MetricTile(
                                title: "People",
                                value: "\(totalStudents)",
                                systemImage: "person.2.fill",
                                tint: .blue
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)

                if sessionsForWeek.isEmpty {
                    ContentUnavailableView {
                        Label("No Socials Planned", systemImage: "figure.badminton")
                    } description: {
                        Text("Add a badminton socials session and attach the students attending that week.")
                    } actions: {
                        Button("Add Socials Session") {
                            editor = SocialSessionEditor(weekStart: weekStart)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(Weekday.allCases) { day in
                        let daySessions = sessionsForWeek.filter { $0.weekday == day }
                        if !daySessions.isEmpty {
                            Section(day.name) {
                                ForEach(daySessions) { session in
                                    Button {
                                        editor = SocialSessionEditor(session: session, weekStart: weekStart)
                                    } label: {
                                        SocialSessionRow(session: session)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            copyNameList(for: session)
                                        } label: {
                                            Label("Copy Names", systemImage: "doc.on.doc")
                                        }
                                        .tint(.blue)
                                    }
                                    .contextMenu {
                                        Button {
                                            copyNameList(for: session)
                                        } label: {
                                            Label("Copy Name List", systemImage: "doc.on.doc")
                                        }
                                    }
                                }
                                .onDelete { offsets in
                                    deleteSessions(at: offsets, from: daySessions)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Socials")
            .scrollContentBackground(.hidden)
            .background(AppStyle.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = SocialSessionEditor(weekStart: weekStart)
                    } label: {
                        Label("Add Socials", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editor) { editor in
                SocialSessionEditorView(editor: editor)
            }
            .alert(item: $copyNotice) { notice in
                Alert(
                    title: Text("Name List Copied"),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .onAppear {
                if socialsWeekStartTimestamp == 0 {
                    let initialWeekStart = sessionsWeekStartTimestamp == 0
                        ? Self.monday(of: .now)
                        : Self.monday(of: Date(timeIntervalSince1970: sessionsWeekStartTimestamp))
                    socialsWeekStartTimestamp = initialWeekStart.timeIntervalSince1970
                }
            }
        }
    }

    private func moveWeek(by offset: Int) {
        let nextWeek = Calendar.current.date(byAdding: .day, value: offset * 7, to: weekStart) ?? weekStart
        socialsWeekStartTimestamp = Self.monday(of: nextWeek).timeIntervalSince1970
    }

    private func deleteSessions(at offsets: IndexSet, from sessions: [SocialSession]) {
        let toDelete = offsets.map { sessions[$0] }
        for session in toDelete {
            modelContext.delete(session)
        }
    }

    private func attendanceCount(for session: SocialSession) -> Int {
        session.attendances.isEmpty ? session.students.count : session.attendances.count
    }

    private func copyNameList(for session: SocialSession) {
        UIPasteboard.general.string = nameListText(for: session)
        copyNotice = SocialCopyNotice(
            message: "The attendance list for \(session.title) is ready to paste."
        )
    }

    private func nameListText(for session: SocialSession) -> String {
        let confirmedNames: [String]
        let pendingNames: [String]

        if session.attendances.isEmpty {
            confirmedNames = sortedNames(session.students.map(\.name))
            pendingNames = []
        } else {
            confirmedNames = participantNames(
                from: session.attendances.filter { $0.statusValue == .confirmed }
            )
            pendingNames = participantNames(
                from: session.attendances.filter { $0.statusValue == .pending }
            )
        }

        return """
        Number of courts: \(session.courtNumbersList.count)

        People coming:
        \(formattedNameList(confirmedNames))

        People I've asked and not replied yet:
        \(formattedNameList(pendingNames))
        """
    }

    private func participantNames(from attendances: [SocialAttendance]) -> [String] {
        sortedNames(
            attendances.compactMap { attendance in
                attendance.student?.name ?? attendance.outsider?.name
            }
        )
    }

    private func sortedNames(_ names: [String]) -> [String] {
        names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func formattedNameList(_ names: [String]) -> String {
        names.isEmpty ? "None" : names.joined(separator: "\n")
    }

    static func monday(of date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? date
    }
}

private struct SocialCopyNotice: Identifiable {
    let id = UUID()
    let message: String
}

private struct SocialSessionRow: View {
    let session: SocialSession

    private var attendanceCount: Int {
        session.attendances.isEmpty ? session.students.count : session.attendances.count
    }

    private var courtSummary: String {
        guard session.areCourtsBooked else { return "" }
        let courts = session.courtNumbersList
        guard !courts.isEmpty else { return "Courts booked" }
        let label = courts.count == 1 ? "Court" : "Courts"
        return "\(label) \(courts.joined(separator: ", "))"
    }

    private var costSummary: String {
        guard session.statusValue == .finished else { return "" }
        let total = session.shuttlecockCost + session.courtCost
        let share = splitAmount(for: session)
        return "Total \(currencyText(total)) · \(currencyText(share)) each"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "figure.badminton")
                    .font(.headline)
                    .foregroundStyle(.purple)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.purple.opacity(0.14)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("\(timeRangeText(start: session.startTime, end: session.endTime)) · \(session.venue)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("\(attendanceCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.purple.opacity(0.14)))

                    if session.statusValue == .finished {
                        Text("Finished")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.green.opacity(0.14)))
                    }
                }
            }

            if !courtSummary.isEmpty {
                Label(courtSummary, systemImage: "rectangle.grid.2x2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
            }

            if !costSummary.isEmpty {
                Label(costSummary, systemImage: "dollarsign.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

        }
        .padding(.vertical, 6)
    }

    private func timeRangeText(start: Date, end: Date) -> String {
        "\(start.formatted(.dateTime.hour().minute()))-\(end.formatted(.dateTime.hour().minute()))"
    }

    private func splitAmount(for session: SocialSession) -> Double {
        let confirmedCount = session.attendances.filter { $0.statusValue == .confirmed }.count
        let participantCount = confirmedCount > 0 ? confirmedCount : attendanceCount
        guard participantCount > 0 else { return 0 }
        return (session.shuttlecockCost + session.courtCost) / Double(participantCount)
    }

    private func currencyText(_ value: Double) -> String {
        value.formatted(.currency(code: Locale.current.currency?.identifier ?? "AUD"))
    }
}

private struct SocialStatusMenu: View {
    let status: SessionStatus
    let onChange: (SessionStatus) -> Void

    var body: some View {
        Menu {
            ForEach(SessionStatus.allCases) { option in
                Button {
                    onChange(option)
                } label: {
                    Label(option.rawValue, systemImage: option.iconName)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(status.rawValue)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(status.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(status.color.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

private struct SocialPaymentMenu: View {
    let status: SocialPaymentStatus
    let onChange: (SocialPaymentStatus) -> Void

    var body: some View {
        Menu {
            ForEach(SocialPaymentStatus.allCases) { option in
                Button {
                    onChange(option)
                } label: {
                    Label(option.rawValue, systemImage: option.iconName)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(status.rawValue)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(status.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(status.color.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

private extension SocialPaymentStatus {
    var color: Color {
        switch self {
        case .unpaid: return .orange
        case .paid: return .green
        }
    }

    var iconName: String {
        switch self {
        case .unpaid: return "exclamationmark.circle.fill"
        case .paid: return "checkmark.circle.fill"
        }
    }
}

private enum SocialPeoplePage: Int, CaseIterable, Identifiable {
    case students
    case outsiders

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .students: return "Students"
        case .outsiders: return "Outsiders"
        }
    }
}

struct SocialSessionEditor: Identifiable {
    let id = UUID()
    let session: SocialSession?
    let weekStart: Date
    let preselectedDay: Weekday?
    let preselectedStartTime: Date?
    let preselectedEndTime: Date?

    init(
        session: SocialSession? = nil,
        weekStart: Date,
        preselectedDay: Weekday? = nil,
        preselectedStartTime: Date? = nil,
        preselectedEndTime: Date? = nil
    ) {
        self.session = session
        self.weekStart = SocialSessionListView.monday(of: weekStart)
        self.preselectedDay = preselectedDay
        self.preselectedStartTime = preselectedStartTime
        self.preselectedEndTime = preselectedEndTime
    }
}

struct SocialSessionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \Student.name) private var students: [Student]
    @Query(sort: \Outsider.name) private var outsiders: [Outsider]
    @Query private var existingSessions: [CoachingSession]
    @AppStorage("weekStartTimestamp") private var sessionsWeekStartTimestamp: Double = 0

    let editor: SocialSessionEditor

    @State private var title: String
    @State private var dayOfWeek: Weekday
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var venue: Venue
    @State private var sessionStatus: SocialSessionStatus
    @State private var areCourtsBooked: Bool
    @State private var courtNumbers: String
    @State private var shuttlecockCostText: String
    @State private var courtCostText: String
    @State private var selectedStatusByStudentID: [PersistentIdentifier: SessionStatus]
    @State private var selectedStatusByOutsiderID: [PersistentIdentifier: SessionStatus]
    @State private var paymentStatusByStudentID: [PersistentIdentifier: SocialPaymentStatus]
    @State private var paymentStatusByOutsiderID: [PersistentIdentifier: SocialPaymentStatus]
    @State private var addPeoplePage: SocialPeoplePage = .students
    @State private var studentSearch = ""
    @State private var outsiderSearch = ""
    @State private var outsiderEditor: OutsiderEditor?
    @State private var contactNotice: SocialContactNotice?

    private var isEditing: Bool { editor.session != nil }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCourtNumbers: String { normalizedCourtNumbers(courtNumbers) }
    private var shuttlecockCost: Double { Double(shuttlecockCostText) ?? 0 }
    private var courtCost: Double { Double(courtCostText) ?? 0 }
    private var totalSocialCost: Double { shuttlecockCost + courtCost }

    init(editor: SocialSessionEditor) {
        self.editor = editor

        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: .now) ?? .now
        let defaultEnd = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: .now) ?? .now

        _title = State(initialValue: editor.session?.title ?? "Badminton Socials")
        _dayOfWeek = State(initialValue: editor.session?.weekday ?? editor.preselectedDay ?? .friday)
        _startTime = State(initialValue: editor.session?.startTime ?? editor.preselectedStartTime ?? defaultStart)
        _endTime = State(initialValue: editor.session?.endTime ?? editor.preselectedEndTime ?? defaultEnd)
        _venue = State(initialValue: editor.session?.venueValue ?? .pbaMalaga)
        _sessionStatus = State(initialValue: editor.session?.statusValue ?? .planned)
        _courtNumbers = State(initialValue: editor.session?.courtNumbers ?? "")
        _areCourtsBooked = State(
            initialValue: editor.session?.areCourtsBooked ?? !(editor.session?.courtNumbersList.isEmpty ?? true)
        )
        _shuttlecockCostText = State(initialValue: Self.costText(for: editor.session?.shuttlecockCost ?? 0))
        _courtCostText = State(initialValue: Self.costText(for: editor.session?.courtCost ?? 0))
        _selectedStatusByStudentID = State(initialValue: Self.initialStudentStatuses(for: editor.session))
        _selectedStatusByOutsiderID = State(initialValue: Self.initialOutsiderStatuses(for: editor.session))
        _paymentStatusByStudentID = State(initialValue: Self.initialStudentPaymentStatuses(for: editor.session))
        _paymentStatusByOutsiderID = State(initialValue: Self.initialOutsiderPaymentStatuses(for: editor.session))
    }

    private var selectedStudents: [Student] {
        students
            .filter { selectedStatusByStudentID[$0.persistentModelID] != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var availableStudents: [Student] {
        let trimmed = studentSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return students
            .filter { selectedStatusByStudentID[$0.persistentModelID] == nil }
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var selectedOutsiders: [Outsider] {
        outsiders
            .filter { selectedStatusByOutsiderID[$0.persistentModelID] != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var availableOutsiders: [Outsider] {
        let trimmed = outsiderSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return outsiders
            .filter { selectedStatusByOutsiderID[$0.persistentModelID] == nil }
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var participantCountForSplit: Int {
        let confirmedStudents = selectedStudents.filter { status(for: $0) == .confirmed }.count
        let confirmedOutsiders = selectedOutsiders.filter { status(for: $0) == .confirmed }.count
        let confirmedCount = confirmedStudents + confirmedOutsiders
        return confirmedCount > 0 ? confirmedCount : selectedStudents.count + selectedOutsiders.count
    }

    private var costPerPerson: Double {
        guard areAllParticipantsConfirmed, participantCountForSplit > 0 else { return 0 }
        return totalSocialCost / Double(participantCountForSplit)
    }

    private var selectedParticipantCount: Int {
        selectedStudents.count + selectedOutsiders.count
    }

    private var areAllParticipantsConfirmed: Bool {
        selectedParticipantCount > 0 &&
            selectedStudents.allSatisfy { status(for: $0) == .confirmed } &&
            selectedOutsiders.allSatisfy { status(for: $0) == .confirmed }
    }

    private var isFinishedSettlementReady: Bool {
        sessionStatus == .finished && areAllParticipantsConfirmed
    }

    private var isTimeValid: Bool {
        minutesOfDay(endTime) > minutesOfDay(startTime)
    }

    private var overlappingSession: CoachingSession? {
        let newStart = minutesOfDay(startTime)
        let newEnd = minutesOfDay(endTime)

        return existingSessions.first { session in
            belongsToEditorWeek(session.weekStart) &&
                session.dayOfWeek == dayOfWeek.rawValue &&
                newStart < minutesOfDay(session.endTime) &&
                newEnd > minutesOfDay(session.startTime)
        }
    }

    private var canSave: Bool {
        trimmedTitle.isEmpty == false &&
            isTimeValid &&
            overlappingSession == nil &&
            (sessionStatus != .finished || areAllParticipantsConfirmed) &&
            shuttlecockCost >= 0 &&
            courtCost >= 0
    }

    private func belongsToEditorWeek(_ recordWeekStart: Date?) -> Bool {
        let normalizedRecordWeekStart: Date
        if let recordWeekStart {
            normalizedRecordWeekStart = SocialSessionListView.monday(of: recordWeekStart)
        } else if sessionsWeekStartTimestamp == 0 {
            normalizedRecordWeekStart = SocialSessionListView.monday(of: .now)
        } else {
            normalizedRecordWeekStart = SocialSessionListView.monday(of: Date(timeIntervalSince1970: sessionsWeekStartTimestamp))
        }
        return Calendar.current.isDate(normalizedRecordWeekStart, inSameDayAs: editor.weekStart)
    }

    private var addStudentsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search students", text: $studentSearch)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            if availableStudents.isEmpty {
                Text(students.isEmpty ? "Add students in the Students tab first." : "No matching students.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(availableStudents) { student in
                            Button {
                                selectedStatusByStudentID[student.persistentModelID] = sessionStatus == .finished ? .confirmed : .unscheduled
                                paymentStatusByStudentID[student.persistentModelID] = .unpaid
                                studentSearch = ""
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "person.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.blue)
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(Color.blue.opacity(0.14)))

                                    Text(student.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Spacer()

                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(AppStyle.surface)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 230)
            }
        }
        .padding(.top, 8)
    }

    private var addOutsidersPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Search outsiders", text: $outsiderSearch)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                Button {
                    outsiderEditor = OutsiderEditor()
                } label: {
                    Label("New", systemImage: "plus.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }

            if availableOutsiders.isEmpty {
                Text(outsiders.isEmpty ? "Create an outsider to add non-students." : "No matching outsiders.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(availableOutsiders) { outsider in
                            HStack(spacing: 10) {
                                Button {
                                    selectedStatusByOutsiderID[outsider.persistentModelID] = sessionStatus == .finished ? .confirmed : .unscheduled
                                    paymentStatusByOutsiderID[outsider.persistentModelID] = .unpaid
                                    outsiderSearch = ""
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "person.crop.circle.badge.questionmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.purple)
                                            .frame(width: 24, height: 24)
                                            .background(Circle().fill(Color.purple.opacity(0.14)))

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(outsider.name)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(outsider.displayContactDetail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .buttonStyle(.plain)

                                Button(role: .destructive) {
                                    deleteOutsider(outsider)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(AppStyle.surface)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 230)
            }
        }
        .padding(.top, 8)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Session name", text: $title)

                    Picker("Day", selection: $dayOfWeek) {
                        ForEach(Weekday.allCases) { day in
                            Text(day.name).tag(day)
                        }
                    }

                    Picker("Venue", selection: $venue) {
                        ForEach(Venue.allCases) { venue in
                            Text(venue.rawValue).tag(venue)
                        }
                    }

                    Picker("Status", selection: $sessionStatus) {
                        ForEach(SocialSessionStatus.allCases) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }

                    LabeledContent("Start Time") {
                        HalfHourTimePicker(selection: $startTime)
                    }

                    LabeledContent("End Time") {
                        HalfHourTimePicker(selection: $endTime)
                    }

                    Toggle("Courts Booked", isOn: $areCourtsBooked.animation())

                    if areCourtsBooked {
                        TextField("Court numbers, e.g. 1, 2, 5", text: $courtNumbers)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Socials Details")
                } footer: {
                    if !isTimeValid {
                        Text("End time must be after start time.")
                            .foregroundStyle(.red)
                    } else if let overlap = overlappingSession {
                        Text("Overlaps with \(overlap.weekday.name) \(timeRangeText(start: overlap.startTime, end: overlap.endTime)) at \(overlap.venue).")
                            .foregroundStyle(.red)
                    } else if sessionStatus == .finished && !areAllParticipantsConfirmed {
                        Text(selectedParticipantCount == 0 ? "Add at least one confirmed person before marking socials as finished." : "Everyone must be confirmed before marking socials as finished.")
                            .foregroundStyle(.red)
                    } else if shuttlecockCost < 0 || courtCost < 0 {
                        Text("Costs cannot be negative.")
                            .foregroundStyle(.red)
                    }
                }

                if sessionStatus == .finished {
                    Section {
                        HStack {
                            Text("Shuttlecocks")
                            Spacer()
                            TextField("0.00", text: $shuttlecockCostText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 110)
                        }

                        HStack {
                            Text("Courts")
                            Spacer()
                            TextField("0.00", text: $courtCostText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 110)
                        }

                        HStack {
                            Text("Split")
                            Spacer()
                            Text(areAllParticipantsConfirmed ? "\(currencyText(costPerPerson)) each" : "Confirm everyone first")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Finished Costs")
                    } footer: {
                        Text("Everyone must be confirmed before the final split is saved.")
                    }
                }

                Section {
                    TextField("Search students", text: $studentSearch)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    if selectedStudents.isEmpty && selectedOutsiders.isEmpty {
                        Text("No people selected")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedStudents) { student in
                            HStack(spacing: 12) {
                                Image(systemName: isFinishedSettlementReady ? paymentStatus(for: student).iconName : status(for: student).iconName)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(isFinishedSettlementReady ? paymentStatus(for: student).color : status(for: student).color)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill((isFinishedSettlementReady ? paymentStatus(for: student).color : status(for: student).color).opacity(0.14)))

                                Text(student.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if !isFinishedSettlementReady {
                                    SocialStatusMenu(
                                        status: status(for: student),
                                        onChange: { newStatus in
                                            selectedStatusByStudentID[student.persistentModelID] = newStatus
                                        }
                                    )
                                }

                                if isFinishedSettlementReady {
                                    SocialPaymentMenu(
                                        status: paymentStatus(for: student),
                                        onChange: { newStatus in
                                            paymentStatusByStudentID[student.persistentModelID] = newStatus
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    ask(student)
                                } label: {
                                    Label("Ask", systemImage: "paperplane.fill")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    selectedStatusByStudentID.removeValue(forKey: student.persistentModelID)
                                    paymentStatusByStudentID.removeValue(forKey: student.persistentModelID)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    if !selectedOutsiders.isEmpty {
                        ForEach(selectedOutsiders) { outsider in
                            HStack(spacing: 12) {
                                Image(systemName: isFinishedSettlementReady ? paymentStatus(for: outsider).iconName : status(for: outsider).iconName)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(isFinishedSettlementReady ? paymentStatus(for: outsider).color : status(for: outsider).color)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill((isFinishedSettlementReady ? paymentStatus(for: outsider).color : status(for: outsider).color).opacity(0.14)))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(outsider.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text("Outsider")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if !isFinishedSettlementReady {
                                    SocialStatusMenu(
                                        status: status(for: outsider),
                                        onChange: { newStatus in
                                            selectedStatusByOutsiderID[outsider.persistentModelID] = newStatus
                                        }
                                    )
                                }

                                if isFinishedSettlementReady {
                                    SocialPaymentMenu(
                                        status: paymentStatus(for: outsider),
                                        onChange: { newStatus in
                                            paymentStatusByOutsiderID[outsider.persistentModelID] = newStatus
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    ask(outsider)
                                } label: {
                                    Label("Ask", systemImage: "paperplane.fill")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    selectedStatusByOutsiderID.removeValue(forKey: outsider.persistentModelID)
                                    paymentStatusByOutsiderID.removeValue(forKey: outsider.persistentModelID)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Name List")
                } footer: {
                    if !selectedStudents.isEmpty || !selectedOutsiders.isEmpty {
                        Text("Swipe right to ask, or swipe left to remove.")
                    }
                }

                Section {
                    Picker("People", selection: $addPeoplePage) {
                        ForEach(SocialPeoplePage.allCases) { page in
                            Text(page.title).tag(page)
                        }
                    }
                    .pickerStyle(.segmented)

                    TabView(selection: $addPeoplePage) {
                        addStudentsPage
                            .tag(SocialPeoplePage.students)

                        addOutsidersPage
                            .tag(SocialPeoplePage.outsiders)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))
                    .frame(minHeight: 320)
                } header: {
                    Text("Add People")
                } footer: {
                    Text("Swipe sideways to switch between students and outsiders.")
                }

                if isEditing {
                    Section {
                        Button("Delete Socials Session", role: .destructive) {
                            deleteSession()
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Socials" : "New Socials")
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
            .sheet(item: $outsiderEditor) { editor in
                OutsiderEditorView(editor: editor) { outsider in
                    addCreatedOutsiderToSession(outsider)
                }
            }
        }
        .presentationContentInteraction(.scrolls)
        .interactiveDismissDisabled()
    }

    private func addCreatedOutsiderToSession(_ outsider: Outsider) {
        selectedStatusByOutsiderID[outsider.persistentModelID] = sessionStatus == .finished ? .confirmed : .unscheduled
        paymentStatusByOutsiderID[outsider.persistentModelID] = .unpaid
        outsiderSearch = ""
        addPeoplePage = .outsiders
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func save() {
        let selected = students.filter { selectedStatusByStudentID[$0.persistentModelID] != nil }
        let selectedOutsiders = outsiders.filter { selectedStatusByOutsiderID[$0.persistentModelID] != nil }
        let attendances = attendanceModels(for: selected, outsiders: selectedOutsiders)

        if let session = editor.session {
            for attendance in session.attendances {
                modelContext.delete(attendance)
            }

            session.title = trimmedTitle
            session.weekStart = editor.weekStart
            session.dayOfWeek = dayOfWeek.rawValue
            session.startTime = startTime
            session.endTime = endTime
            session.venue = venue.rawValue
            session.status = sessionStatus.rawValue
            session.areCourtsBooked = areCourtsBooked
            session.courtNumbers = areCourtsBooked ? trimmedCourtNumbers : ""
            session.shuttlecockCost = sessionStatus == .finished ? shuttlecockCost : 0
            session.courtCost = sessionStatus == .finished ? courtCost : 0
            session.students = selected
            session.attendances = attendances
        } else {
            let session = SocialSession(
                title: trimmedTitle,
                weekStart: editor.weekStart,
                dayOfWeek: dayOfWeek,
                startTime: startTime,
                endTime: endTime,
                venue: venue,
                status: sessionStatus,
                areCourtsBooked: areCourtsBooked,
                courtNumbers: areCourtsBooked ? trimmedCourtNumbers : "",
                shuttlecockCost: sessionStatus == .finished ? shuttlecockCost : 0,
                courtCost: sessionStatus == .finished ? courtCost : 0,
                students: selected,
                attendances: attendances
            )
            modelContext.insert(session)
        }

        dismiss()
    }

    private func deleteSession() {
        if let session = editor.session {
            modelContext.delete(session)
        }
        dismiss()
    }

    private func deleteOutsider(_ outsider: Outsider) {
        selectedStatusByOutsiderID.removeValue(forKey: outsider.persistentModelID)
        paymentStatusByOutsiderID.removeValue(forKey: outsider.persistentModelID)
        modelContext.delete(outsider)
    }

    private func minutesOfDay(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private func timeRangeText(start: Date, end: Date) -> String {
        "\(start.formatted(.dateTime.hour().minute()))-\(end.formatted(.dateTime.hour().minute()))"
    }

    private func normalizedCourtNumbers(_ value: String) -> String {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func ask(_ student: Student) {
        let message = socialAskMessage(for: student)
        let preference = student.contactPreferenceValue

        if requiresClipboardMessage(preference) {
            UIPasteboard.general.string = message
            contactNotice = SocialContactNotice(
                title: "Message Copied",
                message: "Paste the copied socials invite into \(preference.rawValue)."
            )
        }

        guard let url = contactURL(for: student, message: message) else {
            contactNotice = SocialContactNotice(
                title: "Contact Unavailable",
                message: "The contact detail for \(student.name) does not look usable."
            )
            return
        }

        openURL(url)
    }

    private func ask(_ outsider: Outsider) {
        let message = socialAskMessage(for: outsider)
        let preference = outsider.contactPreferenceValue

        if requiresClipboardMessage(preference) {
            UIPasteboard.general.string = message
            contactNotice = SocialContactNotice(
                title: "Message Copied",
                message: "Paste the copied socials invite into \(preference.rawValue)."
            )
        }

        guard let url = contactURL(for: outsider, message: message) else {
            contactNotice = SocialContactNotice(
                title: "Contact Unavailable",
                message: "The contact detail for \(outsider.name) does not look usable."
            )
            return
        }

        openURL(url)
    }

    private func socialAskMessage(for student: Student) -> String {
        "Hey \(firstName(for: student)), wanna come play \(dayOfWeek.name) \(compactTimeRangeText(start: startTime, end: endTime)) at \(venue.rawValue)?"
    }

    private func socialAskMessage(for outsider: Outsider) -> String {
        "Hey \(firstName(for: outsider)), wanna come play \(dayOfWeek.name) \(compactTimeRangeText(start: startTime, end: endTime)) at \(venue.rawValue)?"
    }

    private func firstName(for student: Student) -> String {
        student.name
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? student.name
    }

    private func firstName(for outsider: Outsider) -> String {
        outsider.name
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? outsider.name
    }

    private func compactTimeRangeText(start: Date, end: Date) -> String {
        let calendar = Calendar.current
        let startComps = calendar.dateComponents([.hour, .minute], from: start)
        let endComps = calendar.dateComponents([.hour, .minute], from: end)
        let startHour = startComps.hour ?? 0
        let endHour = endComps.hour ?? 0
        let startPeriod = startHour < 12 ? "am" : "pm"
        let endPeriod = endHour < 12 ? "am" : "pm"
        let includeStartPeriod = startPeriod != endPeriod

        return "\(compactTime(hour: startHour, minute: startComps.minute ?? 0, period: startPeriod, includePeriod: includeStartPeriod))-\(compactTime(hour: endHour, minute: endComps.minute ?? 0, period: endPeriod, includePeriod: true))"
    }

    private func compactTime(
        hour: Int,
        minute: Int,
        period: String,
        includePeriod: Bool
    ) -> String {
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let minuteText = minute == 0 ? "" : ".\(String(format: "%02d", minute))"
        let periodText = includePeriod ? period : ""
        return "\(displayHour)\(minuteText)\(periodText)"
    }

    private func contactURL(for student: Student, message: String) -> URL? {
        contactURL(
            preference: student.contactPreferenceValue,
            detail: student.contactDetail,
            message: message
        )
    }

    private func contactURL(for outsider: Outsider, message: String) -> URL? {
        contactURL(
            preference: outsider.contactPreferenceValue,
            detail: outsider.contactDetail,
            message: message
        )
    }

    private func contactURL(preference: ContactPreference, detail rawDetail: String, message: String) -> URL? {
        let detail = rawDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedMessage = percentEncodedMessage(message)

        switch preference {
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

    private func requiresClipboardMessage(_ preference: ContactPreference) -> Bool {
        switch preference {
        case .instagram, .fbMessenger:
            return true
        case .whatsApp, .sms:
            return false
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

    private func status(for student: Student) -> SessionStatus {
        selectedStatusByStudentID[student.persistentModelID] ?? .unscheduled
    }

    private func status(for outsider: Outsider) -> SessionStatus {
        selectedStatusByOutsiderID[outsider.persistentModelID] ?? .unscheduled
    }

    private func paymentStatus(for student: Student) -> SocialPaymentStatus {
        paymentStatusByStudentID[student.persistentModelID] ?? .unpaid
    }

    private func paymentStatus(for outsider: Outsider) -> SocialPaymentStatus {
        paymentStatusByOutsiderID[outsider.persistentModelID] ?? .unpaid
    }

    private func attendanceModels(for selectedStudents: [Student], outsiders selectedOutsiders: [Outsider]) -> [SocialAttendance] {
        let studentAttendances = selectedStudents.map { student in
            let attendance = SocialAttendance(
                student: student,
                status: sessionStatus == .finished ? .confirmed : selectedStatusByStudentID[student.persistentModelID] ?? .unscheduled,
                paymentStatus: paymentStatusByStudentID[student.persistentModelID] ?? .unpaid
            )
            modelContext.insert(attendance)
            return attendance
        }

        let outsiderAttendances = selectedOutsiders.map { outsider in
            let attendance = SocialAttendance(
                student: nil,
                outsider: outsider,
                status: sessionStatus == .finished ? .confirmed : selectedStatusByOutsiderID[outsider.persistentModelID] ?? .unscheduled,
                paymentStatus: paymentStatusByOutsiderID[outsider.persistentModelID] ?? .unpaid
            )
            modelContext.insert(attendance)
            return attendance
        }

        return studentAttendances + outsiderAttendances
    }

    private static func initialStudentStatuses(for session: SocialSession?) -> [PersistentIdentifier: SessionStatus] {
        guard let session else { return [:] }

        var attendanceStatuses: [PersistentIdentifier: SessionStatus] = [:]
        for attendance in session.attendances {
            guard let student = attendance.student else { continue }
            attendanceStatuses[student.persistentModelID] = attendance.statusValue
        }

        if !attendanceStatuses.isEmpty {
            return attendanceStatuses
        }

        var legacyStatuses: [PersistentIdentifier: SessionStatus] = [:]
        for student in session.students {
            legacyStatuses[student.persistentModelID] = .unscheduled
        }
        return legacyStatuses
    }

    private static func initialOutsiderStatuses(for session: SocialSession?) -> [PersistentIdentifier: SessionStatus] {
        guard let session else { return [:] }

        var attendanceStatuses: [PersistentIdentifier: SessionStatus] = [:]
        for attendance in session.attendances {
            guard let outsider = attendance.outsider else { continue }
            attendanceStatuses[outsider.persistentModelID] = attendance.statusValue
        }
        return attendanceStatuses
    }

    private static func initialStudentPaymentStatuses(for session: SocialSession?) -> [PersistentIdentifier: SocialPaymentStatus] {
        guard let session else { return [:] }

        var paymentStatuses: [PersistentIdentifier: SocialPaymentStatus] = [:]
        for attendance in session.attendances {
            guard let student = attendance.student else { continue }
            paymentStatuses[student.persistentModelID] = attendance.paymentStatusValue
        }
        return paymentStatuses
    }

    private static func initialOutsiderPaymentStatuses(for session: SocialSession?) -> [PersistentIdentifier: SocialPaymentStatus] {
        guard let session else { return [:] }

        var paymentStatuses: [PersistentIdentifier: SocialPaymentStatus] = [:]
        for attendance in session.attendances {
            guard let outsider = attendance.outsider else { continue }
            paymentStatuses[outsider.persistentModelID] = attendance.paymentStatusValue
        }
        return paymentStatuses
    }

    private static func costText(for value: Double) -> String {
        value == 0 ? "" : String(format: "%.2f", value)
    }

    private func currencyText(_ value: Double) -> String {
        value.formatted(.currency(code: Locale.current.currency?.identifier ?? "AUD"))
    }
}

private struct SocialContactNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct OutsiderEditor: Identifiable {
    let id = UUID()
    let outsider: Outsider?

    init(outsider: Outsider? = nil) {
        self.outsider = outsider
    }
}

private struct OutsiderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let editor: OutsiderEditor
    let onCreate: (Outsider) -> Void

    @State private var name: String
    @State private var gender: String
    @State private var contactPreference: ContactPreference
    @State private var contactDetail: String

    private let genderOptions = ["Male", "Female"]

    init(editor: OutsiderEditor, onCreate: @escaping (Outsider) -> Void) {
        self.editor = editor
        self.onCreate = onCreate
        _name = State(initialValue: editor.outsider?.name ?? "")
        _gender = State(initialValue: editor.outsider?.gender ?? "")
        _contactPreference = State(initialValue: editor.outsider?.contactPreferenceValue ?? .instagram)
        _contactDetail = State(initialValue: editor.outsider?.contactDetail ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var outsiderContactDetailBinding: Binding<String> {
        Binding(
            get: {
                switch contactPreference {
                case .instagram:
                    return Self.instagramHandle(from: contactDetail)
                case .whatsApp, .sms:
                    return Self.groupedAustralianLocalDigits(Self.australianLocalDigits(from: contactDetail))
                case .fbMessenger:
                    return Self.facebookProfilePath(from: contactDetail)
                }
            },
            set: { newValue in
                switch contactPreference {
                case .instagram:
                    contactDetail = Self.formattedInstagramHandle(newValue)
                case .whatsApp, .sms:
                    contactDetail = Self.formattedAustralianPhoneNumber(newValue)
                case .fbMessenger:
                    contactDetail = Self.formattedFacebookProfile(newValue)
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Outsider Details") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)

                    Picker("Gender", selection: $gender) {
                        ForEach(genderOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                }

                Section {
                    Picker("Preferred Contact", selection: $contactPreference) {
                        ForEach(ContactPreference.allCases) { preference in
                            Label(preference.rawValue, systemImage: preference.iconName)
                                .tag(preference)
                        }
                    }

                    HStack {
                        switch contactPreference {
                        case .instagram:
                            Text("@")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)

                            TextField("username", text: outsiderContactDetailBinding)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.twitter)
                        case .whatsApp, .sms:
                            Text("+61")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)

                            TextField("412 345 678", text: outsiderContactDetailBinding)
                                .keyboardType(.phonePad)
                        case .fbMessenger:
                            Text("https://facebook.com/")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityHidden(true)

                            TextField("username", text: outsiderContactDetailBinding)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
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
            }
            .navigationTitle(editor.outsider == nil ? "New Outsider" : "Edit Outsider")
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
    }

    private func save() {
        let savedContactDetail = formattedContactDetail()

        if let outsider = editor.outsider {
            outsider.name = trimmedName
            outsider.gender = gender
            outsider.contactPreference = contactPreference.rawValue
            outsider.contactDetail = savedContactDetail
        } else {
            let outsider = Outsider(
                name: trimmedName,
                gender: gender,
                contactPreference: contactPreference,
                contactDetail: savedContactDetail
            )
            modelContext.insert(outsider)
            try? modelContext.save()
            onCreate(outsider)
        }

        dismiss()
    }

    private func formattedContactDetail() -> String {
        switch contactPreference {
        case .instagram:
            return Self.formattedInstagramHandle(contactDetail)
        case .whatsApp, .sms:
            return Self.formattedAustralianPhoneNumber(contactDetail)
        case .fbMessenger:
            return Self.formattedFacebookProfile(contactDetail)
        }
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
        return "+61\(localDigits)"
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
}

#Preview {
    SocialSessionListView()
        .modelContainer(for: [Student.self, StudentHiddenWeek.self, Outsider.self, CoachingSession.self, CourtBooking.self, SocialSession.self, SocialAttendance.self], inMemory: true)
}
