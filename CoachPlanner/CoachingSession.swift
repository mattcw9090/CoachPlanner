import Foundation
import SwiftData

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
    var title: String
    var dayOfWeek: Int
    var startTime: Date
    var endTime: Date
    var venue: String
    var createdAt: Date

    @Relationship(deleteRule: .nullify)
    var students: [Student]

    init(
        title: String,
        dayOfWeek: Weekday,
        startTime: Date,
        endTime: Date,
        venue: Venue,
        students: [Student] = [],
        createdAt: Date = .now
    ) {
        self.title = title
        self.dayOfWeek = dayOfWeek.rawValue
        self.startTime = startTime
        self.endTime = endTime
        self.venue = venue.rawValue
        self.students = students
        self.createdAt = createdAt
    }

    var weekday: Weekday {
        Weekday(rawValue: dayOfWeek) ?? .monday
    }

    var venueValue: Venue {
        Venue(rawValue: venue) ?? .pbaMalaga
    }
}
