import Foundation
import SwiftData
import SwiftUI

protocol SyncTimestamped: AnyObject {
    var updatedAt: Date { get set }
    var lastSyncedAt: Date? { get set }
}

enum SyncTimestamping {
    static var isApplyingRemoteChange = false
}

enum SessionStatus: String, CaseIterable, Identifiable, Codable {
    case unscheduled = "Unscheduled"
    case pending = "Pending"
    case confirmed = "Confirmed"

    var id: String { rawValue }

    /// Coaching sessions no longer use Declined. A legacy value reads as Pending; any other unknown value stays Unscheduled.
    static func coachingValue(fromStored raw: String) -> SessionStatus {
        if raw == "Declined" { return .pending }
        return SessionStatus(rawValue: raw) ?? .unscheduled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self.coachingValue(fromStored: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var color: Color {
        switch self {
        case .unscheduled: return .red
        case .pending: return .yellow
        case .confirmed: return .green
        }
    }

    var iconName: String {
        switch self {
        case .unscheduled: return "exclamationmark.circle.fill"
        case .pending: return "clock.fill"
        case .confirmed: return "checkmark.circle.fill"
        }
    }

    var nextStatus: SessionStatus? {
        switch self {
        case .unscheduled: return .pending
        case .pending: return .confirmed
        case .confirmed: return nil
        }
    }
}

/// A student's reply to one coaching session. This is separate from social attendance.
enum SessionStudentStatus: String, CaseIterable, Identifiable, Codable {
    case pending = "Pending"
    case confirmed = "Confirmed"

    var id: String { rawValue }

    /// A legacy Declined reply reads as Pending. The app does not write Declined.
    static func storedValue(from raw: String) -> SessionStudentStatus {
        if raw == "Declined" { return .pending }
        return SessionStudentStatus(rawValue: raw) ?? .pending
    }

    static func matching(_ sessionStatus: SessionStatus) -> SessionStudentStatus {
        sessionStatus == .confirmed ? .confirmed : .pending
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self.storedValue(from: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var color: Color { sessionStatus.color }
    var iconName: String { sessionStatus.iconName }

    var sessionStatus: SessionStatus {
        switch self {
        case .pending: return .pending
        case .confirmed: return .confirmed
        }
    }
}

enum SessionStatusDerivation {
    /// Every student must accept before the session is confirmed. Otherwise it stays pending.
    static func derived(from studentStatuses: [SessionStudentStatus]) -> SessionStatus {
        if !studentStatuses.isEmpty, studentStatuses.allSatisfy({ $0 == .confirmed }) { return .confirmed }
        return .pending
    }
}

enum Weekday: Int, CaseIterable, Identifiable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        case .sunday: return "Sunday"
        }
    }
}

enum Venue: String, CaseIterable, Identifiable {
    case pbaMalaga = "PBA Malaga"
    case pbaCanningvale = "PBA Canningvale"
    case apex = "Apex"
    case trs = "TRS"

    var id: String { rawValue }
}

@Model
final class CoachingSession: SyncTimestamped {
    var weekStart: Date? = nil
    var dayOfWeek: Int = Weekday.monday.rawValue
    var startTime: Date = Date.now
    var endTime: Date = Date.now
    var venue: String = Venue.pbaMalaga.rawValue
    var status: String = SessionStatus.unscheduled.rawValue
    var courtNumber: String = ""
    var sessionFee: Double = 0
    var sessionDescription: String? = nil
    var createdAt: Date = Date.now
    var syncID: UUID = UUID()
    var updatedAt: Date = Date.now
    var lastSyncedAt: Date? = nil

    @Relationship(deleteRule: .nullify)
    var students: [Student]? = nil

    /// Additive join records. Existing many-to-many memberships stay in `students`
    /// so a lightweight migration does not drop people already on the session.
    @Relationship(deleteRule: .cascade, inverse: \SessionStudentConfirmation.session)
    var studentConfirmations: [SessionStudentConfirmation]? = nil

    init(
        weekStart: Date? = nil,
        dayOfWeek: Weekday,
        startTime: Date,
        endTime: Date,
        venue: Venue,
        status: SessionStatus = .unscheduled,
        courtNumber: String = "",
        sessionFee: Double = 0,
        sessionDescription: String? = nil,
        students: [Student] = [],
        createdAt: Date = .now,
        syncID: UUID = UUID()
    ) {
        self.weekStart = weekStart
        self.dayOfWeek = dayOfWeek.rawValue
        self.startTime = startTime
        self.endTime = endTime
        self.venue = venue.rawValue
        self.status = status.rawValue
        self.courtNumber = courtNumber
        self.sessionFee = sessionFee
        self.sessionDescription = sessionDescription
        self.students = students
        self.createdAt = createdAt
        self.syncID = syncID
    }

    var weekday: Weekday {
        Weekday(rawValue: dayOfWeek) ?? .monday
    }

    var venueValue: Venue {
        Venue(rawValue: venue) ?? .pbaMalaga
    }

    var statusValue: SessionStatus {
        SessionStatus.coachingValue(fromStored: status)
    }

    var studentList: [Student] {
        get { students ?? [] }
        set { students = newValue }
    }

    var confirmationList: [SessionStudentConfirmation] {
        get { studentConfirmations ?? [] }
        set { studentConfirmations = newValue }
    }

    /// Stored session status. Two or more students that have left Unscheduled follow their replies.
    var displayStatus: SessionStatus {
        guard studentList.count > 1, statusValue != .unscheduled else { return statusValue }
        return SessionStatusDerivation.derived(from: studentList.map { confirmationStatus(for: $0) })
    }

    /// Shown on a timetable block when more than one student has a reply to track.
    var confirmationBadgeText: String? {
        let count = studentList.count
        guard count > 1 else { return nil }
        return "\(confirmedStudentCount) of \(count) confirmed"
    }

    var confirmedStudentCount: Int {
        studentList.filter { confirmationStatus(for: $0) == .confirmed }.count
    }

    func confirmationStatus(for student: Student) -> SessionStudentStatus {
        if let record = confirmationRecord(for: student) {
            return record.statusValue
        }
        // Devices that have not stored a reply yet match the cloud backfill:
        // students on an already confirmed session are confirmed, everyone else is pending.
        return statusValue == .confirmed ? .confirmed : .pending
    }

    func respondedAt(for student: Student) -> Date? {
        confirmationRecord(for: student)?.respondedAt
    }

    func confirmationRecord(for student: Student) -> SessionStudentConfirmation? {
        confirmationList.first { $0.student?.syncID == student.syncID }
    }

    /// Writes one student's reply. Passing `registersLocalEdit` as false is for cloud applies.
    func setStudentStatus(
        _ student: Student,
        to status: SessionStudentStatus,
        respondedAt: Date?,
        in context: ModelContext,
        registersLocalEdit: Bool = true
    ) {
        let record = confirmationRecord(for: student) ?? SessionStudentConfirmation(student: student)
        if record.modelContext == nil {
            context.insert(record)
            record.session = self
            if !confirmationList.contains(where: { $0.persistentModelID == record.persistentModelID }) {
                confirmationList = confirmationList + [record]
            }
        }
        record.student = student
        record.status = status.rawValue
        record.respondedAt = respondedAt
        if registersLocalEdit {
            touchForLocalEdit()
        }
    }

    /// Keeps replies for the selected students and drops anyone removed from the session.
    func replaceConfirmations(
        students: [Student],
        statuses: [PersistentIdentifier: SessionStudentStatus],
        respondedAt: [PersistentIdentifier: Date],
        in context: ModelContext
    ) {
        var kept: [SessionStudentConfirmation] = []
        for student in students {
            let status = statuses[student.persistentModelID] ?? confirmationStatus(for: student)
            let response = respondedAt[student.persistentModelID]
            setStudentStatus(student, to: status, respondedAt: response, in: context, registersLocalEdit: false)
            if let record = confirmationRecord(for: student) {
                kept.append(record)
            }
        }
        for stale in confirmationList where !kept.contains(where: { $0.persistentModelID == stale.persistentModelID }) {
            context.delete(stale)
        }
        confirmationList = kept
        touchForLocalEdit()
    }

    /// Copies inferred replies into stored rows before the session status changes.
    /// Otherwise a confirmed session that becomes pending would forget those acceptances.
    func materializeInferredConfirmations(in context: ModelContext) {
        for student in studentList where confirmationRecord(for: student) == nil {
            setStudentStatus(
                student,
                to: confirmationStatus(for: student),
                respondedAt: nil,
                in: context,
                registersLocalEdit: false
            )
        }
    }

    /// Unscheduled sessions stay unscheduled. Every other session with students follows their replies.
    func applyDerivedStatus(in context: ModelContext) {
        guard !studentList.isEmpty, statusValue != .unscheduled else { return }
        materializeInferredConfirmations(in: context)
        let derived = SessionStatusDerivation.derived(from: studentList.map { confirmationStatus(for: $0) }).rawValue
        guard status != derived else { return }
        status = derived
        touchForLocalEdit()
    }

    /// The availability message has been handed off, so an unscheduled session can start collecting replies.
    func noteAvailabilityRequested(in context: ModelContext) {
        guard statusValue == .unscheduled else { return }
        materializeInferredConfirmations(in: context)
        status = SessionStatus.pending.rawValue
        touchForLocalEdit()
        applyDerivedStatus(in: context)
    }

    /// One student's reply follows the session. Unscheduled stores Pending; Pending and Confirmed match.
    func updateStatus(_ newStatus: SessionStatus, in context: ModelContext) {
        let normalized = SessionStatus.coachingValue(fromStored: newStatus.rawValue)
        if studentList.count == 1 {
            writeSingleStudentReply(matching: normalized, in: context, registersLocalEdit: false)
        }
        if status != normalized.rawValue {
            status = normalized.rawValue
        }
        touchForLocalEdit()
    }

    /// Keeps a one-student session and its reply together after a cloud apply.
    func alignSingleStudentReply(in context: ModelContext, registersLocalEdit: Bool) {
        guard studentList.count == 1 else { return }
        writeSingleStudentReply(matching: statusValue, in: context, registersLocalEdit: registersLocalEdit)
    }

    private func writeSingleStudentReply(
        matching sessionStatus: SessionStatus,
        in context: ModelContext,
        registersLocalEdit: Bool
    ) {
        guard studentList.count == 1, let student = studentList.first else { return }
        let reply = SessionStudentStatus.matching(sessionStatus)
        let wasConfirmed = confirmationStatus(for: student) == .confirmed
        let respondedAt: Date? = reply == .confirmed ? (wasConfirmed ? self.respondedAt(for: student) : .now) : nil
        let current = confirmationRecord(for: student)
        if current?.status == reply.rawValue, current?.respondedAt == respondedAt { return }
        if current == nil, confirmationStatus(for: student) == reply, respondedAt == nil { return }
        setStudentStatus(student, to: reply, respondedAt: respondedAt, in: context, registersLocalEdit: registersLocalEdit)
    }

    private func touchForLocalEdit() {
        updatedAt = max(Date(), lastSyncedAt?.addingTimeInterval(0.002) ?? .distantPast)
    }
}

/// Per-student reply stored beside the existing session/student relationship.
/// New optional relationship, so SwiftData can add it without rewriting current rows.
@Model
final class SessionStudentConfirmation {
    var status: String = SessionStudentStatus.pending.rawValue
    var respondedAt: Date? = nil

    @Relationship(deleteRule: .nullify)
    var session: CoachingSession? = nil

    @Relationship(deleteRule: .nullify)
    var student: Student? = nil

    init(
        student: Student,
        status: SessionStudentStatus = .pending,
        respondedAt: Date? = nil
    ) {
        self.student = student
        self.status = status.rawValue
        self.respondedAt = respondedAt
    }

    var statusValue: SessionStudentStatus {
        SessionStudentStatus.storedValue(from: status)
    }
}

@Model
final class CourtBooking: SyncTimestamped {
    var weekStart: Date? = nil
    var dayOfWeek: Int = Weekday.monday.rawValue
    var startTime: Date = Date.now
    var endTime: Date = Date.now
    var venue: String = Venue.pbaMalaga.rawValue
    var courtNumber: String = ""
    var createdAt: Date = Date.now
    var syncID: UUID = UUID()
    var updatedAt: Date = Date.now
    var lastSyncedAt: Date? = nil

    init(
        weekStart: Date? = nil,
        dayOfWeek: Weekday,
        startTime: Date,
        endTime: Date,
        venue: Venue,
        courtNumber: String,
        createdAt: Date = .now,
        syncID: UUID = UUID()
    ) {
        self.weekStart = weekStart
        self.dayOfWeek = dayOfWeek.rawValue
        self.startTime = startTime
        self.endTime = endTime
        self.venue = venue.rawValue
        self.courtNumber = courtNumber
        self.createdAt = createdAt
        self.syncID = syncID
    }

    var weekday: Weekday {
        Weekday(rawValue: dayOfWeek) ?? .monday
    }

    var venueValue: Venue {
        Venue(rawValue: venue) ?? .pbaMalaga
    }
}
