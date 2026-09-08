import Foundation
import SwiftData
import SwiftUI
import UIKit

/// A local, read-only exchange format for planning tools. Contact details are
/// intentionally excluded; external messaging remains a user-controlled step.
struct PlanningSnapshot: Codable {
    var schemaVersion = 1
    var weekStart: String
    var generatedAt: String
    var students: [PlanningStudent]
    var sessions: [PlanningSession]
    var courtBookings: [PlanningCourtBooking]
}

struct PlanningStudent: Codable, Identifiable {
    var id: String
    var name: String
    var sessionsDemand: Int
    var isHiddenForWeek: Bool
    var allocatedSessions: Int
}

struct PlanningSession: Codable, Identifiable {
    var id: String
    var dayOfWeek: Int
    var weekday: String
    var startTime: String
    var endTime: String
    var venue: String
    var status: String
    var courtNumber: String
    var sessionFee: Double
    var studentNames: [String]
}

struct PlanningCourtBooking: Codable, Identifiable {
    var id: String
    var dayOfWeek: Int
    var weekday: String
    var startTime: String
    var endTime: String
    var venue: String
    var courtNumber: String
}

struct PlanningDraftRequest: Codable {
    var weekStart: String
    /// When true, the proposal is evaluated as the complete replacement for the
    /// selected week. Applying that mode requires an explicit destructive confirmation.
    var replacesWeek: Bool = true
    var sessions: [PlanningDraftSession]
}

struct PlanningDraftSession: Codable, Identifiable {
    var id: String
    var dayOfWeek: Int
    var startTime: String
    var endTime: String
    var venue: String
    var studentNames: [String]
}

struct PlanningDraftPreview: Codable {
    var isValid: Bool
    var weekStart: String
    var replacesWeek: Bool
    var proposedSessions: Int
    var allocation: [PlanningAllocation]
    var issues: [PlanningIssue]
}

struct PlanningAllocation: Codable, Identifiable {
    var id: String { studentName }
    var studentName: String
    var requested: Int
    var proposed: Int
    var isHiddenForWeek: Bool
}

struct PlanningIssue: Codable, Identifiable {
    enum Severity: String, Codable { case error, warning }

    var id: String
    var severity: Severity
    var message: String
}

enum PlanningAutomation {
    static func snapshot(
        weekStart: Date,
        students: [Student],
        sessions: [CoachingSession],
        hiddenWeeks: [StudentHiddenWeek],
        courtBookings: [CourtBooking]
    ) -> PlanningSnapshot {
        let normalizedWeekStart = monday(of: weekStart)
        let weekSessions = sessions.filter { belongs($0.weekStart, to: normalizedWeekStart) }
        let hiddenStudentIDs = Set(hiddenWeeks.compactMap { hiddenWeek -> String? in
            guard belongs(hiddenWeek.weekStart, to: normalizedWeekStart), let student = hiddenWeek.student else {
                return nil
            }
            return identifier(for: student)
        })

        return PlanningSnapshot(
            weekStart: dateString(normalizedWeekStart),
            generatedAt: ISO8601DateFormatter().string(from: .now),
            students: students
                .map { student in
                    PlanningStudent(
                        id: identifier(for: student),
                        name: student.name,
                        sessionsDemand: student.sessionsDemand,
                        isHiddenForWeek: student.isHidden || hiddenStudentIDs.contains(identifier(for: student)),
                        allocatedSessions: weekSessions.filter { session in
                            session.studentList.contains { identifier(for: $0) == identifier(for: student) }
                        }.count
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            sessions: weekSessions.map { session in
                PlanningSession(
                    id: identifier(for: session),
                    dayOfWeek: session.dayOfWeek,
                    weekday: session.weekday.name,
                    startTime: timeString(session.startTime),
                    endTime: timeString(session.endTime),
                    venue: session.venue,
                    status: session.status,
                    courtNumber: session.courtNumber,
                    sessionFee: session.sessionFee,
                    studentNames: session.studentList.map(\.name).sorted()
                )
            }
            .sorted { ($0.dayOfWeek, $0.startTime) < ($1.dayOfWeek, $1.startTime) },
            courtBookings: courtBookings.filter { belongs($0.weekStart, to: normalizedWeekStart) }
                .map { booking in
                    PlanningCourtBooking(
                        id: identifier(for: booking),
                        dayOfWeek: booking.dayOfWeek,
                        weekday: booking.weekday.name,
                        startTime: timeString(booking.startTime),
                        endTime: timeString(booking.endTime),
                        venue: booking.venue,
                        courtNumber: booking.courtNumber
                    )
                }
                .sorted { ($0.dayOfWeek, $0.startTime) < ($1.dayOfWeek, $1.startTime) }
        )
    }

    static func preview(
        _ request: PlanningDraftRequest,
        snapshot: PlanningSnapshot
    ) -> PlanningDraftPreview {
        var issues: [PlanningIssue] = []
        let expectedWeekStart = snapshot.weekStart
        if request.weekStart != expectedWeekStart {
            issues.append(issue(.error, "The draft is for \(request.weekStart), but the selected week is \(expectedWeekStart)."))
        }

        let studentsByName = Dictionary(
            snapshot.students.map { ($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var allocations = Dictionary(uniqueKeysWithValues: snapshot.students.map { ($0.name, request.replacesWeek ? 0 : $0.allocatedSessions) })

        for session in request.sessions {
            if !(1...7).contains(session.dayOfWeek) {
                issues.append(issue(.error, "\(session.id): dayOfWeek must be between 1 (Monday) and 7 (Sunday)."))
            }
            if Venue(rawValue: session.venue) == nil {
                issues.append(issue(.error, "\(session.id): \(session.venue) is not a supported venue."))
            }
            guard let start = minutes(session.startTime), let end = minutes(session.endTime) else {
                issues.append(issue(.error, "\(session.id): use 24-hour times in HH:mm format."))
                continue
            }
            if end <= start {
                issues.append(issue(.error, "\(session.id): endTime must be later than startTime."))
            }
            if session.studentNames.isEmpty {
                issues.append(issue(.error, "\(session.id): add at least one student."))
            }
            for name in session.studentNames {
                let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let student = studentsByName[key] else {
                    issues.append(issue(.error, "\(session.id): \(name) is not an active CoachPlanner student."))
                    continue
                }
                if student.isHiddenForWeek {
                    issues.append(issue(.error, "\(session.id): \(student.name) is hidden for this week."))
                }
                allocations[student.name, default: 0] += 1
            }
        }

        for (index, session) in request.sessions.enumerated() {
            guard let start = minutes(session.startTime), let end = minutes(session.endTime) else { continue }
            let names = Set(session.studentNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            for other in request.sessions.dropFirst(index + 1) {
                guard session.dayOfWeek == other.dayOfWeek,
                      let otherStart = minutes(other.startTime), let otherEnd = minutes(other.endTime),
                      start < otherEnd, otherStart < end else { continue }
                let otherNames = Set(other.studentNames.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })
                let overlappingNames = names.intersection(otherNames)
                for name in overlappingNames {
                    let displayName = studentsByName[name]?.name ?? name
                    issues.append(issue(.error, "\(displayName) is scheduled in overlapping draft sessions \(session.id) and \(other.id)."))
                }
            }
        }

        if !request.replacesWeek {
            for session in request.sessions {
                guard let start = minutes(session.startTime), let end = minutes(session.endTime) else { continue }
                let names = Set(session.studentNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                for existing in snapshot.sessions where existing.dayOfWeek == session.dayOfWeek {
                    guard let existingStart = minutes(existing.startTime), let existingEnd = minutes(existing.endTime),
                          start < existingEnd, existingStart < end else { continue }
                    let existingNames = Set(existing.studentNames.map { $0.lowercased() })
                    for name in names.intersection(existingNames) {
                        let displayName = studentsByName[name]?.name ?? name
                        issues.append(issue(.error, "\(displayName) overlaps existing session \(existing.id)."))
                    }
                }
            }
        }

        let allocation: [PlanningAllocation] = snapshot.students.map { student -> PlanningAllocation in
            let proposed = allocations[student.name, default: 0]
            if !student.isHiddenForWeek && proposed < student.sessionsDemand {
                issues.append(issue(.warning, "\(student.name) is underallocated (\(proposed) of \(student.sessionsDemand))."))
            }
            return PlanningAllocation(
                studentName: student.name,
                requested: student.sessionsDemand,
                proposed: proposed,
                isHiddenForWeek: student.isHiddenForWeek
            )
        }.sorted { $0.studentName.localizedCaseInsensitiveCompare($1.studentName) == .orderedAscending }

        return PlanningDraftPreview(
            isValid: !issues.contains { $0.severity == .error },
            weekStart: expectedWeekStart,
            replacesWeek: request.replacesWeek,
            proposedSessions: request.sessions.count,
            allocation: allocation,
            issues: issues
        )
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "Unable to encode planning data."
    }

    static func decodeDraft(_ text: String) throws -> PlanningDraftRequest {
        try JSONDecoder().decode(PlanningDraftRequest.self, from: Data(text.utf8))
    }

    @MainActor
    static func apply(
        _ request: PlanningDraftRequest,
        snapshot: PlanningSnapshot,
        selectedWeekStart: Date,
        students: [Student],
        sessions: [CoachingSession],
        modelContext: ModelContext
    ) throws -> Int {
        let validation = preview(request, snapshot: snapshot)
        guard validation.isValid else {
            throw PlanningApplyError.invalidDraft
        }

        let normalizedWeekStart = monday(of: selectedWeekStart)
        let studentsByName = Dictionary(
            students.map { ($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        if request.replacesWeek {
            for session in sessions where belongs(session.weekStart, to: normalizedWeekStart) {
                modelContext.delete(session)
            }
        }

        for draftSession in request.sessions {
            guard let day = Weekday(rawValue: draftSession.dayOfWeek),
                  let venue = Venue(rawValue: draftSession.venue),
                  let startTime = date(weekStart: normalizedWeekStart, day: day, time: draftSession.startTime),
                  let endTime = date(weekStart: normalizedWeekStart, day: day, time: draftSession.endTime) else {
                throw PlanningApplyError.invalidDraft
            }
            let selectedStudents = try draftSession.studentNames.map { name -> Student in
                let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let student = studentsByName[key] else { throw PlanningApplyError.invalidDraft }
                return student
            }
            modelContext.insert(
                CoachingSession(
                    weekStart: normalizedWeekStart,
                    dayOfWeek: day,
                    startTime: startTime,
                    endTime: endTime,
                    venue: venue,
                    status: .unscheduled,
                    students: selectedStudents
                )
            )
        }

        try modelContext.save()
        return request.sessions.count
    }

    static func monday(of date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)
        return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: start) ?? start
    }

    private static func belongs(_ recordWeekStart: Date?, to targetWeekStart: Date) -> Bool {
        guard let recordWeekStart else { return false }
        return Calendar.current.isDate(monday(of: recordWeekStart), inSameDayAs: monday(of: targetWeekStart))
    }

    private static func identifier<Model: PersistentModel>(for model: Model) -> String {
        String(describing: model.persistentModelID)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func minutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private static func date(weekStart: Date, day: Weekday, time: String) -> Date? {
        guard let minuteOffset = minutes(time),
              let dayDate = Calendar.current.date(byAdding: .day, value: day.rawValue - 1, to: weekStart) else {
            return nil
        }
        return Calendar.current.date(byAdding: .minute, value: minuteOffset, to: dayDate)
    }

    private static func issue(_ severity: PlanningIssue.Severity, _ message: String) -> PlanningIssue {
        PlanningIssue(id: "\(severity.rawValue)-\(message)", severity: severity, message: message)
    }
}

private enum PlanningApplyError: LocalizedError {
    case invalidDraft

    var errorDescription: String? {
        "The draft is no longer valid. Refresh the snapshot, preview the draft again, then apply it."
    }
}

struct PlanningAutomationView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Student.name) private var students: [Student]
    @Query(sort: [SortDescriptor(\CoachingSession.dayOfWeek), SortDescriptor(\CoachingSession.startTime)]) private var sessions: [CoachingSession]
    @Query private var hiddenWeeks: [StudentHiddenWeek]
    @Query(sort: [SortDescriptor(\CourtBooking.dayOfWeek), SortDescriptor(\CourtBooking.startTime)]) private var courtBookings: [CourtBooking]

    @State private var selectedWeekStart = PlanningAutomation.monday(of: .now)
    @State private var snapshotText = ""
    @State private var draftText = ""
    @State private var previewText = ""
    @State private var notice = ""
    @State private var previewedDraft: PlanningDraftRequest?
    @State private var previewedDraftIsValid = false
    @State private var isApplyConfirmationPresented = false

    private var snapshot: PlanningSnapshot {
        PlanningAutomation.snapshot(
            weekStart: selectedWeekStart,
            students: students,
            sessions: sessions,
            hiddenWeeks: hiddenWeeks,
            courtBookings: courtBookings
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Week commencing", selection: $selectedWeekStart, displayedComponents: .date)
                        .onChange(of: selectedWeekStart) { _, value in
                            selectedWeekStart = PlanningAutomation.monday(of: value)
                            refreshSnapshot()
                        }

                    HStack {
                        Button("Refresh snapshot", action: refreshSnapshot)
                        Button("Copy snapshot") {
                            let value = PlanningAutomation.encode(snapshot)
                            UIPasteboard.general.string = value
                            snapshotText = value
                            notice = "Snapshot copied. It contains no contact details."
                        }
                    }

                    if !notice.isEmpty {
                        Text(notice).foregroundStyle(.secondary)
                    }

                    readOnlyJSON(snapshotText)
                } header: {
                    Text("Read-only planning snapshot")
                } footer: {
                    Text("This is a local, read-only JSON contract for planning. It never exposes contact details or changes sessions.")
                }

                Section {
                    TextEditor(text: $draftText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 180)
                        .accessibilityLabel("Draft plan JSON")

                    HStack {
                        Button("Use example") {
                            draftText = exampleDraft()
                        }
                        Button("Preview draft", action: previewDraft)
                            .buttonStyle(.borderedProminent)
                    }

                    if previewedDraftIsValid {
                        Button("Apply approved draft") {
                            isApplyConfirmationPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }

                    if !previewText.isEmpty {
                        readOnlyJSON(previewText)
                    }
                } header: {
                    Text("Draft plan preview")
                } footer: {
                    Text("The preview validates names, hidden students, times, venues, overlapping draft sessions, and allocations. It cannot save a plan.")
                }
            }
            .navigationTitle("Automation")
            .scrollContentBackground(.hidden)
            .background(AppStyle.background)
            .desktopContentWidth(900)
            .onAppear(perform: refreshSnapshot)
            .alert("Apply approved draft?", isPresented: $isApplyConfirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button(applyButtonTitle, role: previewedDraft?.replacesWeek == true ? .destructive : nil) {
                    applyPreviewedDraft()
                }
            } message: {
                Text(applyConfirmationMessage)
            }
        }
    }

    @ViewBuilder
    private func readOnlyJSON(_ text: String) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func refreshSnapshot() {
        snapshotText = PlanningAutomation.encode(snapshot)
        previewText = ""
        notice = ""
        previewedDraft = nil
        previewedDraftIsValid = false
    }

    private func exampleDraft() -> String {
        PlanningAutomation.encode(
            PlanningDraftRequest(
                weekStart: snapshot.weekStart,
                replacesWeek: true,
                sessions: [
                    PlanningDraftSession(
                        id: "monday-1700-apex",
                        dayOfWeek: Weekday.monday.rawValue,
                        startTime: "17:00",
                        endTime: "18:00",
                        venue: Venue.apex.rawValue,
                        studentNames: []
                    )
                ]
            )
        )
    }

    private func previewDraft() {
        do {
            let request = try PlanningAutomation.decodeDraft(draftText)
            let preview = PlanningAutomation.preview(request, snapshot: snapshot)
            previewText = PlanningAutomation.encode(preview)
            previewedDraft = request
            previewedDraftIsValid = preview.isValid
            notice = "Draft preview generated. No sessions were changed."
        } catch {
            previewText = PlanningAutomation.encode(
                PlanningDraftPreview(
                    isValid: false,
                    weekStart: snapshot.weekStart,
                    replacesWeek: true,
                    proposedSessions: 0,
                    allocation: [],
                    issues: [PlanningIssue(
                        id: "invalid-json",
                        severity: .error,
                        message: "Invalid draft JSON: \(error.localizedDescription)"
                    )]
                )
            )
            previewedDraft = nil
            previewedDraftIsValid = false
            notice = "Fix the JSON and preview again. No sessions were changed."
        }
    }

    private var applyButtonTitle: String {
        previewedDraft?.replacesWeek == true ? "Replace and apply" : "Create sessions"
    }

    private var applyConfirmationMessage: String {
        guard let draft = previewedDraft else { return "No valid draft is ready to apply." }
        if draft.replacesWeek {
            return "This replaces all coaching sessions in \(snapshot.weekStart) with \(draft.sessions.count) draft sessions. Existing session statuses, fees, and court numbers will be removed. Court bookings are not changed."
        }
        return "This adds \(draft.sessions.count) new Unscheduled coaching sessions. Existing sessions and court bookings are not changed."
    }

    private func applyPreviewedDraft() {
        guard let draft = previewedDraft else { return }
        do {
            let count = try PlanningAutomation.apply(
                draft,
                snapshot: snapshot,
                selectedWeekStart: selectedWeekStart,
                students: students,
                sessions: sessions,
                modelContext: modelContext
            )
            refreshSnapshot()
            notice = "Applied \(count) draft sessions. No messages were prepared or sent."
        } catch {
            notice = error.localizedDescription
        }
    }
}
