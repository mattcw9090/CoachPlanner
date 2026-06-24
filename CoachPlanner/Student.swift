import Foundation
import SwiftData

@Model
final class Student {
    var name: String
    var notes: String
    var createdAt: Date

    init(name: String, notes: String = "", createdAt: Date = .now) {
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
    }
}
