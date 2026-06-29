import Foundation
import SwiftData

@Model
final class SocialSession {
    var title: String
    var weekStart: Date
    var dayOfWeek: Int
    var startTime: Date
    var endTime: Date
    var venue: String
    var notes: String
    var createdAt: Date

    @Relationship(deleteRule: .nullify)
    var students: [Student]

    init(
        title: String = "Badminton Socials",
        weekStart: Date,
        dayOfWeek: Weekday,
        startTime: Date,
        endTime: Date,
        venue: Venue,
        notes: String = "",
        students: [Student] = [],
        createdAt: Date = .now
    ) {
        self.title = title
        self.weekStart = weekStart
        self.dayOfWeek = dayOfWeek.rawValue
        self.startTime = startTime
        self.endTime = endTime
        self.venue = venue.rawValue
        self.notes = notes
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
