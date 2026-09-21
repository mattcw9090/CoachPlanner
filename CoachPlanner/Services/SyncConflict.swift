import Foundation

/// An in-memory description of a conflict found by the normal sync check.
/// Reading this value never selects a winner or changes either version.
struct SyncConflict: Identifiable, Equatable {
    let id: String
    let table: String
    let recordID: UUID
    let entityName: String
    let title: String
    let detectedAt: Date
    let localUpdatedAt: Date?
    let cloudUpdatedAt: Date?
    let reason: String
    let differences: [SyncConflictDifference]
}

struct SyncConflictDifference: Identifiable, Equatable {
    let id: String
    let label: String
    let localValue: String
    let cloudValue: String
}
