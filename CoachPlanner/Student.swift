import Foundation
import SwiftData

enum Gender: String, Codable, CaseIterable {
    case male = "Male"
    case female = "Female"
}

@Model
final class Student {
    var name: String
    var gender: Gender
    var notes: String
    var createdAt: Date

    init(
        name: String,
        gender: Gender,
        notes: String = "",
        createdAt: Date = .now
    ) {
        self.name = name
        self.gender = gender
        self.notes = notes
        self.createdAt = createdAt
    }
}
