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
    var title: String
    var weekStart: Date
    var dayOfWeek: Int
    var startTime: Date
    var endTime: Date
    var venue: String
    var status: String = SocialSessionStatus.planned.rawValue
    var areCourtsBooked: Bool = false
    var courtNumbers: String = ""
    var shuttlecockCost: Double = 0
    var courtCost: Double = 0
    var createdAt: Date

    @Relationship(deleteRule: .nullify)
    var students: [Student]

    // Retained to migrate hidden selections saved by earlier app versions.
    @Relationship(deleteRule: .nullify)
    var hiddenStudents: [Student] = []

    @Relationship(deleteRule: .nullify)
    var hiddenOutsiders: [Outsider] = []

    @Relationship(deleteRule: .cascade, inverse: \SocialHiddenPerson.session)
    var hiddenPeople: [SocialHiddenPerson] = []

    @Relationship(deleteRule: .cascade)
    var attendances: [SocialAttendance] = []

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

    var courtNumbersList: [String] {
        courtNumbers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

@Model
final class SocialHiddenPerson {
    var createdAt: Date
    var session: SocialSession?
    var student: Student?
    var outsider: Outsider?

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
    var status: String
    var paymentStatus: String = SocialPaymentStatus.unpaid.rawValue
    var createdAt: Date

    @Relationship(deleteRule: .nullify)
    var student: Student?

    @Relationship(deleteRule: .nullify)
    var outsider: Outsider?

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
