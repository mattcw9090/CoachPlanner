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
final class SocialSession {
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
        createdAt: Date = .now
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
final class SocialHiddenPerson {
    var createdAt: Date = Date.now
    var session: SocialSession? = nil
    var student: Student? = nil
    var outsider: Outsider? = nil

    init(student: Student, createdAt: Date = .now) {
        self.student = student
        self.outsider = nil
        self.createdAt = createdAt
    }

    init(outsider: Outsider, createdAt: Date = .now) {
        self.student = nil
        self.outsider = outsider
        self.createdAt = createdAt
    }
}

@Model
final class SocialAttendance {
    var status: String = SessionStatus.unscheduled.rawValue
    var paymentStatus: String = SocialPaymentStatus.unpaid.rawValue
    var createdAt: Date = Date.now

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
        createdAt: Date = .now
    ) {
        self.student = student
        self.outsider = outsider
        self.status = status.rawValue
        self.paymentStatus = paymentStatus.rawValue
        self.createdAt = createdAt
    }

    var statusValue: SessionStatus {
        SessionStatus(rawValue: status) ?? .unscheduled
    }

    var paymentStatusValue: SocialPaymentStatus {
        SocialPaymentStatus(rawValue: paymentStatus) ?? .unpaid
    }
}
