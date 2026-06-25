import Foundation
import SwiftData

@Model
final class Student {
    var name: String
    var gender: String
    var sessionsDemand: Int
    var createdAt: Date

    init(name: String, gender: String, sessionsDemand: Int = 1, createdAt: Date = .now) {
        self.name = name
        self.gender = gender
        self.sessionsDemand = sessionsDemand
        self.createdAt = createdAt
    }
}
