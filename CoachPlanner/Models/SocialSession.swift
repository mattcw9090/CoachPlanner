import Foundation
import SwiftData

enum SocialSessionStatus: String, CaseIterable, Identifiable {
    case planned = "Planned"
    case finished = "Finished"

    var id: String { rawValue }
}

enum SocialPaymentStatus: String, CaseIterable, Identifiable {
    case unpaid = "Unpaid"
    case paid = "Paid"

    var id: String { rawValue }
}

@Model
final class SocialSession: SyncTimestamped {
    var title: String = "Badminton Socials"
    var weekStart: Date = Date.now
    var dayOfWeek: Int = Weekday.monday.rawValue
    var startTime: Date = Date.now
    var endTime: Date = Date.now
    var venue: String = Venue.pbaMalaga.rawValue
    var status: String = SocialSessionStatus.planned.rawValue
    var areCourtsBooked: Bool = false
    var courtNumbers: String = ""
    var shuttlecockCost: Double = 0
    var courtCost: Double = 0
    var createdAt: Date = Date.now
    var syncID: UUID = UUID()
    var updatedAt: Date = Date.now
    var lastSyncedAt: Date? = nil

    @Relationship(deleteRule: .nullify)
    var students: [Student]? = nil

    // Retained to migrate hidden selections saved by earlier app versions.
    @Relationship(deleteRule: .nullify)
    var hiddenStudents: [Student]? = nil

    @Relationship(deleteRule: .nullify)
    var hiddenOutsiders: [Outsider]? = nil

    @Relationship(deleteRule: .cascade, inverse: \SocialHiddenPerson.session)
    var hiddenPeople: [SocialHiddenPerson]? = nil

    @Relationship(deleteRule: .cascade, inverse: \SocialAttendance.session)
    var attendances: [SocialAttendance]? = nil

    init(
        title: String = "Badminton Socials",
        weekStart: Date,
        dayOfWeek: Weekday,
        startTime: Date,
        endTime: Date,
        venue: Venue,
        status: SocialSessionStatus = .planned,
        areCourtsBooked: Bool = false,
        courtNumbers: String = "",
        shuttlecockCost: Double = 0,
        courtCost: Double = 0,
        students: [Student] = [],
        hiddenStudents: [Student] = [],
        hiddenOutsiders: [Outsider] = [],
        hiddenPeople: [SocialHiddenPerson] = [],
        attendances: [SocialAttendance] = [],
        createdAt: Date = .now,
        syncID: UUID = UUID()
    ) {
        self.title = title
        self.weekStart = weekStart
        self.dayOfWeek = dayOfWeek.rawValue
        self.startTime = startTime
        self.endTime = endTime
        self.venue = venue.rawValue
        self.status = status.rawValue
        self.areCourtsBooked = areCourtsBooked
        self.courtNumbers = courtNumbers
        self.shuttlecockCost = shuttlecockCost
        self.courtCost = courtCost
        self.students = students
        self.hiddenStudents = hiddenStudents
        self.hiddenOutsiders = hiddenOutsiders
        self.hiddenPeople = hiddenPeople
        self.attendances = attendances
        self.createdAt = createdAt
        self.syncID = syncID
    }

    var weekday: Weekday {
        Weekday(rawValue: dayOfWeek) ?? .monday
    }

    var venueValue: Venue {
        Venue(rawValue: venue) ?? .pbaMalaga
    }

    var statusValue: SocialSessionStatus {
        SocialSessionStatus(rawValue: status) ?? .planned
    }

    var studentList: [Student] {
        get { students ?? [] }
        set { students = newValue }
    }

    var legacyHiddenStudentList: [Student] {
        get { hiddenStudents ?? [] }
        set { hiddenStudents = newValue }
    }

    var legacyHiddenOutsiderList: [Outsider] {
        get { hiddenOutsiders ?? [] }
        set { hiddenOutsiders = newValue }
    }

    var hiddenPersonList: [SocialHiddenPerson] {
        get { hiddenPeople ?? [] }
        set { hiddenPeople = newValue }
    }

    var attendanceList: [SocialAttendance] {
        get { attendances ?? [] }
        set { attendances = newValue }
    }

    var courtNumbersList: [String] {
        courtNumbers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

@Model
final class SocialHiddenPerson: SyncTimestamped {
    var createdAt: Date = Date.now
    var syncID: UUID = UUID()
    var updatedAt: Date = Date.now
    var lastSyncedAt: Date? = nil
    var session: SocialSession? = nil
    var student: Student? = nil
    var outsider: Outsider? = nil

    init(student: Student, createdAt: Date = .now, syncID: UUID = UUID()) {
        self.student = student
        self.outsider = nil
        self.createdAt = createdAt
        self.syncID = syncID
    }

    init(outsider: Outsider, createdAt: Date = .now, syncID: UUID = UUID()) {
        self.student = nil
        self.outsider = outsider
        self.createdAt = createdAt
        self.syncID = syncID
    }
}

@Model
final class SocialAttendance: SyncTimestamped {
    var status: String = SessionStatus.unscheduled.rawValue
    var paymentStatus: String = SocialPaymentStatus.unpaid.rawValue
    var createdAt: Date = Date.now
    var syncID: UUID = UUID()
    var updatedAt: Date = Date.now
    var lastSyncedAt: Date? = nil

    @Relationship(deleteRule: .nullify)
    var session: SocialSession? = nil

    @Relationship(deleteRule: .nullify)
    var student: Student? = nil

    @Relationship(deleteRule: .nullify)
    var outsider: Outsider? = nil

    init(
        student: Student?,
        outsider: Outsider? = nil,
        status: SessionStatus = .unscheduled,
        paymentStatus: SocialPaymentStatus = .unpaid,
        createdAt: Date = .now,
        syncID: UUID = UUID()
    ) {
        self.student = student
        self.outsider = outsider
        self.status = status.rawValue
        self.paymentStatus = paymentStatus.rawValue
        self.createdAt = createdAt
        self.syncID = syncID
    }

    var statusValue: SessionStatus {
        SessionStatus(rawValue: status) ?? .unscheduled
    }

    var paymentStatusValue: SocialPaymentStatus {
        SocialPaymentStatus(rawValue: paymentStatus) ?? .unpaid
    }
}

/// Transient editor values; these do not add persisted fields to the schema.
enum SocialEditorPerson {
    case student(Student)
    case outsider(Outsider)

    var student: Student? { if case .student(let value) = self { return value }; return nil }
    var outsider: Outsider? { if case .outsider(let value) = self { return value }; return nil }
    var key: String {
        switch self {
        case .student(let value): return "student:\(value.syncID.uuidString)"
        case .outsider(let value): return "outsider:\(value.syncID.uuidString)"
        }
    }
}

struct SocialAttendanceEdit {
    let person: SocialEditorPerson
    let status: SessionStatus
    let paymentStatus: SocialPaymentStatus
}

extension SocialSession {
    /// Keep existing child identities and timestamps. A payment-only edit must
    /// not become deletion/recreation of every attendee and hidden person.
    func applyEditorRelationships(attendance edits: [SocialAttendanceEdit], hidden people: [SocialEditorPerson], in context: ModelContext) {
        var remainingAttendance = attendanceList
        var resultAttendance: [SocialAttendance] = []
        for edit in edits {
            let record: SocialAttendance
            if let index = remainingAttendance.firstIndex(where: {
                SocialSessionEditorSnapshot.personKey(student: $0.student, outsider: $0.outsider) == edit.person.key
            }) {
                record = remainingAttendance.remove(at: index)
                if record.status != edit.status.rawValue { record.status = edit.status.rawValue }
                if record.paymentStatus != edit.paymentStatus.rawValue { record.paymentStatus = edit.paymentStatus.rawValue }
            } else {
                record = SocialAttendance(student: edit.person.student, outsider: edit.person.outsider,
                                          status: edit.status, paymentStatus: edit.paymentStatus)
                context.insert(record)
                record.session = self
            }
            resultAttendance.append(record)
        }
        for removed in remainingAttendance { context.delete(removed) }
        if Set(attendanceList.map(\.persistentModelID)) != Set(resultAttendance.map(\.persistentModelID)) {
            attendanceList = resultAttendance
        }

        var remainingHidden = hiddenPersonList
        var resultHidden: [SocialHiddenPerson] = []
        for person in people {
            let record: SocialHiddenPerson
            if let index = remainingHidden.firstIndex(where: {
                SocialSessionEditorSnapshot.personKey(student: $0.student, outsider: $0.outsider) == person.key
            }) {
                record = remainingHidden.remove(at: index)
            } else {
                switch person {
                case .student(let student): record = SocialHiddenPerson(student: student)
                case .outsider(let outsider): record = SocialHiddenPerson(outsider: outsider)
                }
                context.insert(record)
                record.session = self
            }
            resultHidden.append(record)
        }
        for removed in remainingHidden { context.delete(removed) }
        if Set(hiddenPersonList.map(\.persistentModelID)) != Set(resultHidden.map(\.persistentModelID)) {
            hiddenPersonList = resultHidden
        }
    }
}

/// Compare meaningful editor inputs, not sync acknowledgements or replacement
/// child UUIDs. This prevents an open draft from overwriting a later cloud pull.
struct SocialSessionEditorSnapshot: Equatable {
    private let fields: [String]
    private let students: [String]
    private let hiddenPeople: [String]
    private let attendances: [[String]]

    init(_ session: SocialSession) {
        fields = [session.syncID.uuidString, session.title, String(session.weekStart.timeIntervalSince1970),
                  String(session.dayOfWeek), String(session.startTime.timeIntervalSince1970),
                  String(session.endTime.timeIntervalSince1970), session.venue, session.status,
                  String(session.areCourtsBooked), session.courtNumbers, String(session.shuttlecockCost), String(session.courtCost)]
        students = session.studentList.map { $0.syncID.uuidString }.sorted()
        hiddenPeople = (session.hiddenPersonList.compactMap { Self.personKey(student: $0.student, outsider: $0.outsider) }
            + session.legacyHiddenStudentList.map { SocialEditorPerson.student($0).key }
            + session.legacyHiddenOutsiderList.map { SocialEditorPerson.outsider($0).key }).sorted()
        attendances = session.attendanceList.compactMap { record in
            Self.personKey(student: record.student, outsider: record.outsider).map { [$0, record.status, record.paymentStatus] }
        }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    func matches(_ session: SocialSession, ignoringDeletedOutsiders ids: Set<UUID> = []) -> Bool {
        guard !session.isDeleted, session.modelContext != nil else { return false }
        let current = Self(session)
        let ignored = Set(ids.map { "outsider:\($0.uuidString)" })
        return fields == current.fields && students == current.students &&
            hiddenPeople.filter { !ignored.contains($0) } == current.hiddenPeople.filter { !ignored.contains($0) } &&
            attendances.filter { !ignored.contains($0[0]) } == current.attendances.filter { !ignored.contains($0[0]) }
    }

    fileprivate static func personKey(student: Student?, outsider: Outsider?) -> String? {
        if let student { return SocialEditorPerson.student(student).key }
        if let outsider { return SocialEditorPerson.outsider(outsider).key }
        return nil
    }
}
