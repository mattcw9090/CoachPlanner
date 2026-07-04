import Foundation
import SwiftData
import SwiftUI

enum SessionStatus: String, CaseIterable, Identifiable {
    case unscheduled = "Unscheduled"
    case pending = "Pending"
    case confirmed = "Confirmed"

    var id: String { rawValue }

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
final class CoachingSession {
    var weekStart: Date?
    var dayOfWeek: Int
    var startTime: Date
    var endTime: Date
    var venue: String
    var status: String
    var courtNumber: String = ""
    var sessionFee: Double = 0
    var createdAt: Date

    @Relationship(deleteRule: .nullify)
    var students: [Student]

    init(
        weekStart: Date? = nil,
        dayOfWeek: Weekday,
        startTime: Date,
        endTime: Date,
        venue: Venue,
        status: SessionStatus = .unscheduled,
        courtNumber: String = "",
        sessionFee: Double = 0,
        students: [Student] = [],
        createdAt: Date = .now
    ) {
        self.weekStart = weekStart
        self.dayOfWeek = dayOfWeek.rawValue
        self.startTime = startTime
        self.endTime = endTime
        self.venue = venue.rawValue
        self.status = status.rawValue
        self.courtNumber = courtNumber
        self.sessionFee = sessionFee
        self.students = students
        self.createdAt = createdAt
    }

    var weekday: Weekday {
        Weekday(rawValue: dayOfWeek) ?? .monday
    }

    var venueValue: Venue {
        Venue(rawValue: venue) ?? .pbaMalaga
    }

    var statusValue: SessionStatus {
        SessionStatus(rawValue: status) ?? .unscheduled
    }
}

@Model
final class CourtBooking {
    var weekStart: Date?
    var dayOfWeek: Int
    var startTime: Date
    var endTime: Date
    var venue: String
    var courtNumber: String
    var createdAt: Date

    init(
        weekStart: Date? = nil,
        dayOfWeek: Weekday,
        startTime: Date,
        endTime: Date,
        venue: Venue,
        courtNumber: String,
        createdAt: Date = .now
    ) {
        self.weekStart = weekStart
        self.dayOfWeek = dayOfWeek.rawValue
        self.startTime = startTime
        self.endTime = endTime
        self.venue = venue.rawValue
        self.courtNumber = courtNumber
        self.createdAt = createdAt
    }

    var weekday: Weekday {
        Weekday(rawValue: dayOfWeek) ?? .monday
    }

    var venueValue: Venue {
        Venue(rawValue: venue) ?? .pbaMalaga
    }
}
