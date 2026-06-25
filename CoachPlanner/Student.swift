import Foundation
import SwiftData

@Model
final class Student {
    var name: String
    var gender: String
    var createdAt: Date

    init(name: String, gender: String, createdAt: Date = .now) {
        self.name = name
        self.gender = gender
        self.createdAt = createdAt
    }
}
