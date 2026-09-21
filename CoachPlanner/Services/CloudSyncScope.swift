import Foundation

/// Parent records whose complete payload and relationships need reconciliation.
/// An empty set means no work for that table, never a full-table download.
struct CloudSyncScope: Codable, Equatable, Sendable {
    var students: Set<UUID> = []
    var outsiders: Set<UUID> = []
    var courtBookings: Set<UUID> = []
    var socialSessions: Set<UUID> = []
    var coachingSessions: Set<UUID> = []

    var isEmpty: Bool {
        students.isEmpty && outsiders.isEmpty && courtBookings.isEmpty &&
            socialSessions.isEmpty && coachingSessions.isEmpty
    }

    mutating func formUnion(_ other: Self) {
        students.formUnion(other.students)
        outsiders.formUnion(other.outsiders)
        courtBookings.formUnion(other.courtBookings)
        socialSessions.formUnion(other.socialSessions)
        coachingSessions.formUnion(other.coachingSessions)
    }

    mutating func insert(table: String, id: UUID) {
        switch table {
        case "students": students.insert(id)
        case "outsiders": outsiders.insert(id)
        case "court_bookings": courtBookings.insert(id)
        case "social_sessions": socialSessions.insert(id)
        case "coaching_sessions": coachingSessions.insert(id)
        default: break
        }
    }
}
