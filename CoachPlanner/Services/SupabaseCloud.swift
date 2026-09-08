import Combine
import Foundation
import Security
import SwiftData

enum SupabaseConfiguration {
    static let projectURL = URL(string: "https://bgpjpimhrnmthamzqsgv.supabase.co")!
    static let publishableKey = "sb_publishable_Y6P3ePpdP3hDlwvBuxpSkQ_ec1LNexw"
    static let workspaceID = UUID(uuidString: "0db2b4f5-ff7c-4fbd-b71b-e2ddf9d5def6")!
}

@MainActor
final class SupabaseCloud: ObservableObject {
    static let shared = SupabaseCloud()

    @Published private(set) var isSignedIn = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncResult: SyncRunResult?
    @Published private(set) var isSyncing = false

    private let keychain = SupabaseKeychain()
    private var accessToken: String?
    private var syncLedger = SupabaseSyncLedger.load()

    private init() {
        accessToken = keychain.read("access_token")
        isSignedIn = accessToken != nil
    }

    func signIn(email: String, password: String) async {
        lastError = nil
        do {
            let session = try await authenticate(email: email, password: password)
            try await verifyWorkspaceAccess(token: session.accessToken)
            accessToken = session.accessToken
            keychain.write(session.accessToken, key: "access_token")
            if let refreshToken = session.refreshToken {
                keychain.write(refreshToken, key: "refresh_token")
            }
            isSignedIn = true
        } catch {
            isSignedIn = false
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        accessToken = nil
        isSignedIn = false
        lastSyncResult = nil
        keychain.delete("access_token")
        keychain.delete("refresh_token")
    }

    func syncAll(in context: ModelContext) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncResult = nil
        let autosaveWasEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer {
            context.autosaveEnabled = autosaveWasEnabled
            isSyncing = false
        }

        lastError = nil
        do {
            try await renewAccessToken()
            guard let accessToken else { throw SupabaseCloudError.notSignedIn }
            try await verifyWorkspaceAccess(token: accessToken)
        } catch {
            lastError = error.localizedDescription
            return
        }

        let startingLedger = syncLedger
        var combined = SyncRunResult.zero

        await syncStudentsAndOutsiders(in: context)
        guard lastError == nil, let peopleResult = lastSyncResult else {
            syncLedger = startingLedger
            lastSyncResult = nil
            return
        }
        combined = combined.adding(peopleResult)

        await syncCourtsSocialsAndAttendance(in: context)
        guard lastError == nil, let socialResult = lastSyncResult else {
            syncLedger = startingLedger
            lastSyncResult = nil
            return
        }
        combined = combined.adding(socialResult)

        await syncCoachingSessions(in: context)
        guard lastError == nil, let sessionResult = lastSyncResult else {
            syncLedger = startingLedger
            lastSyncResult = nil
            return
        }
        combined = combined.adding(sessionResult)
        lastSyncResult = combined
        syncLedger.save()
    }

    private func syncCoachingSessions(in context: ModelContext) async {
        lastError = nil
        do {
            guard let accessToken else { throw SupabaseCloudError.notSignedIn }
            let localSessions = try context.fetch(FetchDescriptor<CoachingSession>())
            let localStudents = try context.fetch(FetchDescriptor<Student>())
            let cloudSessions = try await fetchSessionRecords(token: accessToken)
            let cloudLinks = try await fetchCoachingSessionStudentLinks(token: accessToken)
            let studentByID = localStudents.reduce(into: [UUID: Student]()) { $0[$1.syncID] = $1 }
            let cloudStudentIDsBySession = Dictionary(grouping: cloudLinks, by: \.sessionID)
                .mapValues { Set($0.map(\.studentID)) }
            var remainingCloud = Dictionary(uniqueKeysWithValues: cloudSessions.map { ($0.id, $0) })
            var nextLedger: [String: Date] = [:]
            var pushed = 0
            var pulled = 0
            var conflicts = 0
            let skipped = 0
            var cloudOnly = 0

            for local in localSessions {
                let ledgerKey = SupabaseSyncLedger.key(for: local.syncID)
                guard let cloud = remainingCloud.removeValue(forKey: local.syncID) else {
                    if local.lastSyncedAt == nil || syncLedger.coachingSessions[ledgerKey] == nil {
                        var created = try await insertCloudSession(local, token: accessToken)
                        try await replaceCloudStudents(for: local, token: accessToken)
                        created = try await fetchCurrentSession(id: local.syncID, token: accessToken)
                        local.updatedAt = created.updatedAt
                        local.lastSyncedAt = created.updatedAt
                        nextLedger[ledgerKey] = created.updatedAt
                        pushed += 1
                    } else {
                        SyncTimestamping.isApplyingRemoteChange = true
                        context.delete(local)
                        SyncTimestamping.isApplyingRemoteChange = false
                        pulled += 1
                    }
                    continue
                }


                if cloud.deletedAt != nil {
                    try await cleanupCloudRelationships(forSessionID: cloud.id, token: accessToken)
                    SyncTimestamping.isApplyingRemoteChange = true
                    context.delete(local)
                    SyncTimestamping.isApplyingRemoteChange = false
                    pulled += 1
                    continue
                }

                let baseline = local.lastSyncedAt ?? cloud.updatedAt
                if local.lastSyncedAt == nil {
                    local.lastSyncedAt = baseline
                }
                var localChanged = local.updatedAt > baseline
                let cloudChanged = cloud.updatedAt > baseline
                let localStudentIDs = Set(local.studentList.map(\.syncID))
                let cloudStudentIDs = cloudStudentIDsBySession[local.syncID] ?? []
                let payloadsMatch = cloud.matchesPayload(of: local) && localStudentIDs == cloudStudentIDs
                if !localChanged && !cloudChanged &&
                    !payloadsMatch {
                    localChanged = true
                }
                if localChanged && cloudChanged {
                    if payloadsMatch {
                        local.updatedAt = cloud.updatedAt
                        local.lastSyncedAt = cloud.updatedAt
                        nextLedger[ledgerKey] = cloud.updatedAt
                    } else {
                        conflicts += 1
                        nextLedger[ledgerKey] = baseline
                    }
                } else if localChanged {
                    _ = try await updateCloudSession(local, expectedUpdatedAt: baseline, token: accessToken)
                    try await replaceCloudStudents(for: local, token: accessToken)
                    let updated = try await fetchCurrentSession(id: local.syncID, token: accessToken)
                    local.updatedAt = updated.updatedAt
                    local.lastSyncedAt = updated.updatedAt
                    nextLedger[ledgerKey] = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
                    SyncTimestamping.isApplyingRemoteChange = true
                    apply(cloud, to: local)
                    local.studentList = cloudStudentIDs.compactMap { studentByID[$0] }
                    SyncTimestamping.isApplyingRemoteChange = false
                    nextLedger[ledgerKey] = cloud.updatedAt
                    pulled += 1
                } else {
                    nextLedger[ledgerKey] = cloud.updatedAt
                }
            }

            for cloud in remainingCloud.values {
                guard cloud.deletedAt == nil else {
                    try await cleanupCloudRelationships(forSessionID: cloud.id, token: accessToken)
                    continue
                }
                let ledgerKey = SupabaseSyncLedger.key(for: cloud.id)
                if let baseline = syncLedger.coachingSessions[ledgerKey] {
                    if cloud.updatedAt > baseline.addingTimeInterval(0.001) {
                        conflicts += 1
                        cloudOnly += 1
                        nextLedger[ledgerKey] = baseline
                    } else {
                        try await softDeleteCloudRecord(
                            table: "coaching_sessions",
                            id: cloud.id,
                            expectedUpdatedAt: baseline,
                            token: accessToken
                        )
                        try await cleanupCloudRelationships(forSessionID: cloud.id, token: accessToken)
                        pushed += 1
                    }
                } else {
                    let studentIDs = cloudStudentIDsBySession[cloud.id] ?? []
                    let students = studentIDs.compactMap { studentByID[$0] }
                    guard students.count == studentIDs.count else {
                        throw SupabaseCloudError.invalidResponse
                    }
                    SyncTimestamping.isApplyingRemoteChange = true
                    context.insert(makeLocalSession(from: cloud, students: students))
                    SyncTimestamping.isApplyingRemoteChange = false
                    nextLedger[ledgerKey] = cloud.updatedAt
                    pulled += 1
                }
            }

            try saveSyncChanges(in: context)
            syncLedger.coachingSessions = nextLedger
            lastSyncResult = SyncRunResult(
                pushed: pushed,
                pulled: pulled,
                conflicts: conflicts,
                skipped: skipped,
                cloudOnly: cloudOnly
            )
        } catch {
            SyncTimestamping.isApplyingRemoteChange = false
            lastError = error.localizedDescription
        }
    }

    private func syncStudentsAndOutsiders(in context: ModelContext) async {
        lastError = nil
        do {
            guard let accessToken else { throw SupabaseCloudError.notSignedIn }
            let localStudents = try context.fetch(FetchDescriptor<Student>())
            let localOutsiders = try context.fetch(FetchDescriptor<Outsider>())
            let cloudStudents = try await fetchStudentRecords(token: accessToken)
            let cloudOutsiders = try await fetchOutsiderRecords(token: accessToken)
            let cloudHiddenWeeks = try await fetchHiddenWeekRecords(token: accessToken)
            var remainingCloudStudents = Dictionary(uniqueKeysWithValues: cloudStudents.map { ($0.id, $0) })
            var remainingCloudOutsiders = Dictionary(uniqueKeysWithValues: cloudOutsiders.map { ($0.id, $0) })
            let hiddenWeeksByStudent = Dictionary(grouping: cloudHiddenWeeks, by: \.studentID)
            var nextStudentLedger: [String: Date] = [:]
            var nextOutsiderLedger: [String: Date] = [:]
            var pushed = 0
            var pulled = 0
            var conflicts = 0
            let skipped = 0
            var cloudOnly = 0

            for student in localStudents {
                let ledgerKey = SupabaseSyncLedger.key(for: student.syncID)
                guard let cloud = remainingCloudStudents.removeValue(forKey: student.syncID) else {
                    if student.lastSyncedAt == nil || syncLedger.students[ledgerKey] == nil {
                        var created = try await insertCloudStudent(student, token: accessToken)
                        try await replaceCloudHiddenWeeks(for: student, token: accessToken)
                        created = try await fetchCurrentStudent(id: student.syncID, token: accessToken)
                        student.updatedAt = created.updatedAt
                        student.lastSyncedAt = created.updatedAt
                        for hiddenWeek in student.hiddenWeeks ?? [] {
                            hiddenWeek.updatedAt = created.updatedAt
                            hiddenWeek.lastSyncedAt = created.updatedAt
                        }
                        nextStudentLedger[ledgerKey] = created.updatedAt
                        pushed += 1
                    } else {
                        SyncTimestamping.isApplyingRemoteChange = true
                        try deleteLocalStudent(student, in: context)
                        SyncTimestamping.isApplyingRemoteChange = false
                        pulled += 1
                    }
                    continue
                }

                if cloud.deletedAt != nil {
                    try await cleanupCloudRelationships(forStudentID: cloud.id, token: accessToken)
                    SyncTimestamping.isApplyingRemoteChange = true
                    try deleteLocalStudent(student, in: context)
                    SyncTimestamping.isApplyingRemoteChange = false
                    pulled += 1
                    continue
                }

                let baseline = student.lastSyncedAt ?? cloud.updatedAt
                if student.lastSyncedAt == nil {
                    student.lastSyncedAt = baseline
                }
                var localChanged = student.updatedAt > baseline
                let cloudChanged = cloud.updatedAt > baseline
                let localHiddenWeekKeys = Set((student.hiddenWeeks ?? []).map { Self.dateOnlyFormatter.string(from: $0.weekStart) })
                let cloudHiddenWeekKeys = Set((hiddenWeeksByStudent[student.syncID] ?? []).map { Self.dateOnlyFormatter.string(from: $0.weekStart) })
                let payloadsMatch = cloud.matchesPayload(of: student) && localHiddenWeekKeys == cloudHiddenWeekKeys
                if !localChanged && !cloudChanged &&
                    !payloadsMatch {
                    localChanged = true
                }
                if localChanged && cloudChanged {
                    if payloadsMatch {
                        student.updatedAt = cloud.updatedAt
                        student.lastSyncedAt = cloud.updatedAt
                        for hiddenWeek in student.hiddenWeeks ?? [] {
                            hiddenWeek.updatedAt = cloud.updatedAt
                            hiddenWeek.lastSyncedAt = cloud.updatedAt
                        }
                        nextStudentLedger[ledgerKey] = cloud.updatedAt
                    } else {
                        conflicts += 1
                        nextStudentLedger[ledgerKey] = baseline
                    }
                } else if localChanged {
                    _ = try await updateCloudStudent(student, expectedUpdatedAt: baseline, token: accessToken)
                    try await replaceCloudHiddenWeeks(for: student, token: accessToken)
                    let updated = try await fetchCurrentStudent(id: student.syncID, token: accessToken)
                    student.updatedAt = updated.updatedAt
                    student.lastSyncedAt = updated.updatedAt
                    for hiddenWeek in student.hiddenWeeks ?? [] {
                        hiddenWeek.updatedAt = updated.updatedAt
                        hiddenWeek.lastSyncedAt = updated.updatedAt
                    }
                    nextStudentLedger[ledgerKey] = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
                    SyncTimestamping.isApplyingRemoteChange = true
                    apply(cloud, to: student)
                    applyCloudHiddenWeeks(
                        hiddenWeeksByStudent[student.syncID] ?? [],
                        to: student,
                        in: context,
                        parentTimestamp: cloud.updatedAt
                    )
                    SyncTimestamping.isApplyingRemoteChange = false
                    nextStudentLedger[ledgerKey] = cloud.updatedAt
                    pulled += 1
                } else {
                    nextStudentLedger[ledgerKey] = cloud.updatedAt
                }
            }

            for cloud in remainingCloudStudents.values {
                guard cloud.deletedAt == nil else {
                    try await cleanupCloudRelationships(forStudentID: cloud.id, token: accessToken)
                    continue
                }
                let ledgerKey = SupabaseSyncLedger.key(for: cloud.id)
                if let baseline = syncLedger.students[ledgerKey] {
                    if cloud.updatedAt > baseline.addingTimeInterval(0.001) {
                        conflicts += 1
                        cloudOnly += 1
                        nextStudentLedger[ledgerKey] = baseline
                    } else {
                        try await softDeleteCloudRecord(
                            table: "students",
                            id: cloud.id,
                            expectedUpdatedAt: baseline,
                            token: accessToken
                        )
                        try await cleanupCloudRelationships(forStudentID: cloud.id, token: accessToken)
                        pushed += 1
                    }
                } else {
                    SyncTimestamping.isApplyingRemoteChange = true
                    let student = makeLocalStudent(from: cloud)
                    context.insert(student)
                    applyCloudHiddenWeeks(
                        hiddenWeeksByStudent[cloud.id] ?? [],
                        to: student,
                        in: context,
                        parentTimestamp: cloud.updatedAt
                    )
                    SyncTimestamping.isApplyingRemoteChange = false
                    nextStudentLedger[ledgerKey] = cloud.updatedAt
                    pulled += 1
                }
            }

            for outsider in localOutsiders {
                let ledgerKey = SupabaseSyncLedger.key(for: outsider.syncID)
                guard let cloud = remainingCloudOutsiders.removeValue(forKey: outsider.syncID) else {
                    if outsider.lastSyncedAt == nil || syncLedger.outsiders[ledgerKey] == nil {
                        let created = try await insertCloudOutsider(outsider, token: accessToken)
                        outsider.updatedAt = created.updatedAt
                        outsider.lastSyncedAt = created.updatedAt
                        nextOutsiderLedger[ledgerKey] = created.updatedAt
                        pushed += 1
                    } else {
                        SyncTimestamping.isApplyingRemoteChange = true
                        try deleteLocalOutsider(outsider, in: context)
                        SyncTimestamping.isApplyingRemoteChange = false
                        pulled += 1
                    }
                    continue
                }

                if cloud.deletedAt != nil {
                    try await cleanupCloudRelationships(forOutsiderID: cloud.id, token: accessToken)
                    SyncTimestamping.isApplyingRemoteChange = true
                    try deleteLocalOutsider(outsider, in: context)
                    SyncTimestamping.isApplyingRemoteChange = false
                    pulled += 1
                    continue
                }

                let baseline = outsider.lastSyncedAt ?? cloud.updatedAt
                if outsider.lastSyncedAt == nil {
                    outsider.lastSyncedAt = baseline
                }
                var localChanged = outsider.updatedAt > baseline
                let cloudChanged = cloud.updatedAt > baseline
                let payloadsMatch = cloud.matchesPayload(of: outsider)
                if !localChanged && !cloudChanged && !payloadsMatch {
                    localChanged = true
                }
                if localChanged && cloudChanged {
                    if payloadsMatch {
                        outsider.updatedAt = cloud.updatedAt
                        outsider.lastSyncedAt = cloud.updatedAt
                        nextOutsiderLedger[ledgerKey] = cloud.updatedAt
                    } else {
                        conflicts += 1
                        nextOutsiderLedger[ledgerKey] = baseline
                    }
                } else if localChanged {
                    let updated = try await updateCloudOutsider(outsider, expectedUpdatedAt: baseline, token: accessToken)
                    outsider.updatedAt = updated.updatedAt
                    outsider.lastSyncedAt = updated.updatedAt
                    nextOutsiderLedger[ledgerKey] = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
                    SyncTimestamping.isApplyingRemoteChange = true
                    apply(cloud, to: outsider)
                    SyncTimestamping.isApplyingRemoteChange = false
                    nextOutsiderLedger[ledgerKey] = cloud.updatedAt
                    pulled += 1
                } else {
                    nextOutsiderLedger[ledgerKey] = cloud.updatedAt
                }
            }

            for cloud in remainingCloudOutsiders.values {
                guard cloud.deletedAt == nil else {
                    try await cleanupCloudRelationships(forOutsiderID: cloud.id, token: accessToken)
                    continue
                }
                let ledgerKey = SupabaseSyncLedger.key(for: cloud.id)
                if let baseline = syncLedger.outsiders[ledgerKey] {
                    if cloud.updatedAt > baseline.addingTimeInterval(0.001) {
                        conflicts += 1
                        cloudOnly += 1
                        nextOutsiderLedger[ledgerKey] = baseline
                    } else {
                        try await softDeleteCloudRecord(
                            table: "outsiders",
                            id: cloud.id,
                            expectedUpdatedAt: baseline,
                            token: accessToken
                        )
                        try await cleanupCloudRelationships(forOutsiderID: cloud.id, token: accessToken)
                        pushed += 1
                    }
                } else {
                    SyncTimestamping.isApplyingRemoteChange = true
                    let outsider = makeLocalOutsider(from: cloud)
                    context.insert(outsider)
                    SyncTimestamping.isApplyingRemoteChange = false
                    nextOutsiderLedger[ledgerKey] = cloud.updatedAt
                    pulled += 1
                }
            }

            try saveSyncChanges(in: context)
            syncLedger.students = nextStudentLedger
            syncLedger.outsiders = nextOutsiderLedger
            lastSyncResult = SyncRunResult(
                pushed: pushed,
                pulled: pulled,
                conflicts: conflicts,
                skipped: skipped,
                cloudOnly: cloudOnly
            )
        } catch {
            SyncTimestamping.isApplyingRemoteChange = false
            lastError = error.localizedDescription
        }
    }

    private func syncCourtsSocialsAndAttendance(in context: ModelContext) async {
        lastError = nil
        do {
            guard let accessToken else { throw SupabaseCloudError.notSignedIn }
            let courtResult = try await syncCourtBookings(in: context, token: accessToken)
            let socialResult = try await syncSocialSessions(in: context, token: accessToken)
            lastSyncResult = courtResult.adding(socialResult)
        } catch {
            SyncTimestamping.isApplyingRemoteChange = false
            lastError = error.localizedDescription
        }
    }

    private func syncCourtBookings(in context: ModelContext, token: String) async throws -> SyncRunResult {
        let localBookings = try context.fetch(FetchDescriptor<CourtBooking>())
        let cloudBookings = try await fetchCourtRecords(token: token)
        var remainingCloud = Dictionary(uniqueKeysWithValues: cloudBookings.map { ($0.id, $0) })
        var nextLedger: [String: Date] = [:]
        var pushed = 0
        var pulled = 0
        var conflicts = 0
        var cloudOnly = 0

        for booking in localBookings {
            let ledgerKey = SupabaseSyncLedger.key(for: booking.syncID)
            guard let cloud = remainingCloud.removeValue(forKey: booking.syncID) else {
                if booking.lastSyncedAt == nil || syncLedger.courtBookings[ledgerKey] == nil {
                    let created = try await insertCloudCourtBooking(booking, token: token)
                    booking.updatedAt = created.updatedAt
                    booking.lastSyncedAt = created.updatedAt
                    nextLedger[ledgerKey] = created.updatedAt
                    pushed += 1
                } else {
                    SyncTimestamping.isApplyingRemoteChange = true
                    context.delete(booking)
                    SyncTimestamping.isApplyingRemoteChange = false
                    pulled += 1
                }
                continue
            }

            if cloud.deletedAt != nil {
                SyncTimestamping.isApplyingRemoteChange = true
                context.delete(booking)
                SyncTimestamping.isApplyingRemoteChange = false
                pulled += 1
                continue
            }

            let baseline = booking.lastSyncedAt ?? cloud.updatedAt
            if booking.lastSyncedAt == nil { booking.lastSyncedAt = baseline }
            var localChanged = booking.updatedAt > baseline
            let cloudChanged = cloud.updatedAt > baseline
            let payloadsMatch = cloud.matchesPayload(of: booking)
            if !localChanged && !cloudChanged && !payloadsMatch {
                localChanged = true
            }

            if localChanged && cloudChanged {
                if payloadsMatch {
                    booking.updatedAt = cloud.updatedAt
                    booking.lastSyncedAt = cloud.updatedAt
                    nextLedger[ledgerKey] = cloud.updatedAt
                } else {
                    conflicts += 1
                    nextLedger[ledgerKey] = baseline
                }
            } else if localChanged {
                let updated = try await updateCloudCourtBooking(
                    booking,
                    expectedUpdatedAt: baseline,
                    token: token
                )
                booking.updatedAt = updated.updatedAt
                booking.lastSyncedAt = updated.updatedAt
                nextLedger[ledgerKey] = updated.updatedAt
                pushed += 1
            } else if cloudChanged {
                SyncTimestamping.isApplyingRemoteChange = true
                apply(cloud, to: booking)
                SyncTimestamping.isApplyingRemoteChange = false
                nextLedger[ledgerKey] = cloud.updatedAt
                pulled += 1
            } else {
                nextLedger[ledgerKey] = cloud.updatedAt
            }
        }

        for cloud in remainingCloud.values where cloud.deletedAt == nil {
            let ledgerKey = SupabaseSyncLedger.key(for: cloud.id)
            if let baseline = syncLedger.courtBookings[ledgerKey] {
                if cloud.updatedAt > baseline.addingTimeInterval(0.001) {
                    conflicts += 1
                    cloudOnly += 1
                    nextLedger[ledgerKey] = baseline
                } else {
                    try await softDeleteCloudRecord(
                        table: "court_bookings",
                        id: cloud.id,
                        expectedUpdatedAt: baseline,
                        token: token
                    )
                    pushed += 1
                }
            } else {
                SyncTimestamping.isApplyingRemoteChange = true
                context.insert(makeLocalCourtBooking(from: cloud))
                SyncTimestamping.isApplyingRemoteChange = false
                nextLedger[ledgerKey] = cloud.updatedAt
                pulled += 1
            }
        }

        try saveSyncChanges(in: context)
        syncLedger.courtBookings = nextLedger
        return SyncRunResult(
            pushed: pushed,
            pulled: pulled,
            conflicts: conflicts,
            skipped: 0,
            cloudOnly: cloudOnly
        )
    }

    private func syncSocialSessions(in context: ModelContext, token: String) async throws -> SyncRunResult {
        try removeOrphanedSocialChildren(in: context)
        let localSocials = try context.fetch(FetchDescriptor<SocialSession>())
        let localStudents = try context.fetch(FetchDescriptor<Student>())
        let localOutsiders = try context.fetch(FetchDescriptor<Outsider>())
        let cloudSocials = try await fetchSocialRecords(token: token)
        let cloudStudentLinks = try await fetchSocialSessionStudentLinks(token: token)
        let cloudHiddenPeople = try await fetchHiddenPersonRecords(token: token)
        let cloudAttendances = try await fetchAttendanceRecords(token: token)

        let studentsByID = localStudents.reduce(into: [UUID: Student]()) { $0[$1.syncID] = $1 }
        let outsidersByID = localOutsiders.reduce(into: [UUID: Outsider]()) { $0[$1.syncID] = $1 }
        let studentIDsBySocial = Dictionary(grouping: cloudStudentLinks, by: \.sessionID)
            .mapValues { Set($0.map(\.studentID)) }
        let hiddenPeopleBySocial = Dictionary(grouping: cloudHiddenPeople, by: \.socialSessionID)
        let attendancesBySocial = Dictionary(grouping: cloudAttendances, by: \.socialSessionID)
        var remainingCloud = Dictionary(uniqueKeysWithValues: cloudSocials.map { ($0.id, $0) })
        var nextLedger: [String: Date] = [:]
        var pushed = 0
        var pulled = 0
        var conflicts = 0
        var cloudOnly = 0

        for social in localSocials {
            let ledgerKey = SupabaseSyncLedger.key(for: social.syncID)
            guard let cloud = remainingCloud.removeValue(forKey: social.syncID) else {
                if social.lastSyncedAt == nil || syncLedger.socialSessions[ledgerKey] == nil {
                    var created = try await insertCloudSocialSession(social, token: token)
                    try await replaceCloudRelationships(for: social, token: token)
                    created = try await fetchCurrentSocial(id: social.syncID, token: token)
                    social.updatedAt = created.updatedAt
                    social.lastSyncedAt = created.updatedAt
                    stampSocialChildren(social, parentTimestamp: created.updatedAt)
                    nextLedger[ledgerKey] = created.updatedAt
                    pushed += 1
                } else {
                    SyncTimestamping.isApplyingRemoteChange = true
                    context.delete(social)
                    SyncTimestamping.isApplyingRemoteChange = false
                    pulled += 1
                }
                continue
            }

            if cloud.deletedAt != nil {
                try await cleanupCloudRelationships(forSocialID: cloud.id, token: token)
                SyncTimestamping.isApplyingRemoteChange = true
                context.delete(social)
                SyncTimestamping.isApplyingRemoteChange = false
                pulled += 1
                continue
            }

            let baseline = social.lastSyncedAt ?? cloud.updatedAt
            if social.lastSyncedAt == nil { social.lastSyncedAt = baseline }
            var localChanged = social.updatedAt > baseline
            let cloudChanged = cloud.updatedAt > baseline
            let cloudStudentIDs = studentIDsBySocial[social.syncID] ?? []
            let cloudHidden = hiddenPeopleBySocial[social.syncID] ?? []
            let cloudAttendance = attendancesBySocial[social.syncID] ?? []
            let localHiddenKeys = Set(social.hiddenPersonList.compactMap(\.syncParticipantKey))
            let cloudHiddenKeys = Set(cloudHidden.compactMap(\.participantKey))
            let localAttendanceValues = Set(social.attendanceList.compactMap(\.syncValue))
            let cloudAttendanceValues = Set(cloudAttendance.compactMap(\.syncValue))
            let relationshipsMatch = Set(social.studentList.map(\.syncID)) == cloudStudentIDs &&
                localHiddenKeys == cloudHiddenKeys &&
                social.hiddenPersonList.count == cloudHidden.count &&
                localAttendanceValues == cloudAttendanceValues &&
                social.attendanceList.count == cloudAttendance.count
            let payloadsMatch = cloud.matchesPayload(of: social) && relationshipsMatch

            if !localChanged && !cloudChanged &&
                !payloadsMatch {
                localChanged = true
            }

            if localChanged && cloudChanged {
                if payloadsMatch {
                    social.updatedAt = cloud.updatedAt
                    social.lastSyncedAt = cloud.updatedAt
                    stampSocialChildren(social, parentTimestamp: cloud.updatedAt)
                    nextLedger[ledgerKey] = cloud.updatedAt
                } else {
                    conflicts += 1
                    nextLedger[ledgerKey] = baseline
                }
            } else if localChanged {
                _ = try await updateCloudSocialSession(
                    social,
                    expectedUpdatedAt: baseline,
                    token: token
                )
                try await replaceCloudRelationships(for: social, token: token)
                let updated = try await fetchCurrentSocial(id: social.syncID, token: token)
                social.updatedAt = updated.updatedAt
                social.lastSyncedAt = updated.updatedAt
                stampSocialChildren(social, parentTimestamp: updated.updatedAt)
                nextLedger[ledgerKey] = updated.updatedAt
                pushed += 1
            } else if cloudChanged {
                SyncTimestamping.isApplyingRemoteChange = true
                apply(cloud, to: social)
                try applyCloudRelationships(
                    to: social,
                    studentIDs: cloudStudentIDs,
                    hiddenPeople: cloudHidden,
                    attendances: cloudAttendance,
                    studentsByID: studentsByID,
                    outsidersByID: outsidersByID,
                    in: context,
                    parentTimestamp: cloud.updatedAt
                )
                SyncTimestamping.isApplyingRemoteChange = false
                nextLedger[ledgerKey] = cloud.updatedAt
                pulled += 1
            } else {
                nextLedger[ledgerKey] = cloud.updatedAt
            }
        }

        for cloud in remainingCloud.values {
            guard cloud.deletedAt == nil else {
                try await cleanupCloudRelationships(forSocialID: cloud.id, token: token)
                continue
            }
            let ledgerKey = SupabaseSyncLedger.key(for: cloud.id)
            if let baseline = syncLedger.socialSessions[ledgerKey] {
                if cloud.updatedAt > baseline.addingTimeInterval(0.001) {
                    conflicts += 1
                    cloudOnly += 1
                    nextLedger[ledgerKey] = baseline
                } else {
                    try await softDeleteCloudRecord(
                        table: "social_sessions",
                        id: cloud.id,
                        expectedUpdatedAt: baseline,
                        token: token
                    )
                    try await cleanupCloudRelationships(forSocialID: cloud.id, token: token)
                    pushed += 1
                }
            } else {
                let studentIDs = studentIDsBySocial[cloud.id] ?? []
                let students = studentIDs.compactMap { studentsByID[$0] }
                guard students.count == studentIDs.count else {
                    throw SupabaseCloudError.invalidResponse
                }
                SyncTimestamping.isApplyingRemoteChange = true
                let social = makeLocalSocialSession(from: cloud, students: students)
                context.insert(social)
                try applyCloudRelationships(
                    to: social,
                    studentIDs: studentIDs,
                    hiddenPeople: hiddenPeopleBySocial[cloud.id] ?? [],
                    attendances: attendancesBySocial[cloud.id] ?? [],
                    studentsByID: studentsByID,
                    outsidersByID: outsidersByID,
                    in: context,
                    parentTimestamp: cloud.updatedAt
                )
                SyncTimestamping.isApplyingRemoteChange = false
                nextLedger[ledgerKey] = cloud.updatedAt
                pulled += 1
            }
        }

        try saveSyncChanges(in: context)
        syncLedger.socialSessions = nextLedger
        return SyncRunResult(
            pushed: pushed,
            pulled: pulled,
            conflicts: conflicts,
            skipped: 0,
            cloudOnly: cloudOnly
        )
    }

    private func saveSyncChanges(in context: ModelContext) throws {
        guard context.hasChanges else { return }
        SyncTimestamping.isApplyingRemoteChange = true
        defer { SyncTimestamping.isApplyingRemoteChange = false }
        try context.save()
    }

    private func renewAccessToken() async throws {
        guard let refreshToken = keychain.read("refresh_token"), !refreshToken.isEmpty else {
            throw SupabaseCloudError.notSignedIn
        }

        let url = SupabaseConfiguration.projectURL
            .appendingPathComponent("auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        let body = try JSONEncoder().encode(["refresh_token": refreshToken])
        let session = try await authenticateSession(url: url, body: body)
        accessToken = session.accessToken
        keychain.write(session.accessToken, key: "access_token")
        if let rotatedRefreshToken = session.refreshToken {
            keychain.write(rotatedRefreshToken, key: "refresh_token")
        }
        isSignedIn = true
    }

    private func authenticate(email: String, password: String) async throws -> AuthSession {
        let url = SupabaseConfiguration.projectURL
            .appendingPathComponent("auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "password")])
        let body = try JSONEncoder().encode(["email": email, "password": password])
        return try await authenticateSession(url: url, body: body)
    }

    private func authenticateSession(url: URL, body: Data) async throws -> AuthSession {
        let data = try await send(url: url, method: "POST", body: body, authenticated: false)
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    private func verifyWorkspaceAccess(token: String) async throws {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/workspaces"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)")
        ]
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        let workspaces = try JSONDecoder().decode([CloudID].self, from: data)
        guard workspaces.contains(where: { $0.id == SupabaseConfiguration.workspaceID }) else {
            throw SupabaseCloudError.workspaceUnavailable
        }
    }

    private func fetchStudentRecords(token: String) async throws -> [CloudStudentRecord] {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/students"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,name,gender,contact_preference,contact_detail,sessions_demand,is_hidden,created_at,updated_at,deleted_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)")
        ]
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        return try decoder.decode([CloudStudentRecord].self, from: data)
    }

    private func fetchSessionRecords(token: String) async throws -> [CloudSessionRecord] {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/coaching_sessions"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,week_start,day_of_week,start_time,end_time,venue,status,court_number,session_fee,session_description,created_at,updated_at,deleted_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)"),
            URLQueryItem(name: "order", value: "start_time.asc")
        ]
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        return try decoder.decode([CloudSessionRecord].self, from: data)
    }

    private func updateCloudSession(
        _ session: CoachingSession,
        expectedUpdatedAt: Date,
        token: String
    ) async throws -> CloudSessionRecord {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/coaching_sessions"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(session.syncID.uuidString)"),
            URLQueryItem(name: "updated_at", value: "gte.\(Self.isoFormatter.string(from: expectedUpdatedAt.addingTimeInterval(-0.001)))"),
            URLQueryItem(name: "updated_at", value: "lte.\(Self.isoFormatter.string(from: expectedUpdatedAt.addingTimeInterval(0.001)))")
        ]
        let body: [String: Any] = [
            "week_start": session.weekStart.map { Self.dateOnlyFormatter.string(from: $0) } ?? NSNull(),
            "day_of_week": session.dayOfWeek,
            "start_time": Self.isoFormatter.string(from: session.effectiveStartTime),
            "end_time": Self.isoFormatter.string(from: session.effectiveEndTime),
            "venue": session.venue,
            "status": session.status,
            "court_number": session.courtNumber,
            "session_fee": session.sessionFee,
            "session_description": session.sessionDescription ?? NSNull()
        ]
        let data = try await send(
            url: components.url!, method: "PATCH",
            body: try JSONSerialization.data(withJSONObject: body),
            token: token,
            prefer: "return=representation"
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        guard let updated = try decoder.decode([CloudSessionRecord].self, from: data).first else {
            throw SupabaseCloudError.conflict
        }
        return updated
    }

    private func updateCloudStudent(_ student: Student, expectedUpdatedAt: Date, token: String) async throws -> CloudStudentRecord {
        let body: [String: Any] = [
            "name": student.name, "gender": student.gender,
            "contact_preference": student.contactPreference, "contact_detail": student.contactDetail,
            "sessions_demand": student.sessionsDemand, "is_hidden": student.isHidden
        ]
        return try await updateCloudRecord(table: "students", id: student.syncID, body: body, expectedUpdatedAt: expectedUpdatedAt, token: token)
    }

    private func updateCloudOutsider(_ outsider: Outsider, expectedUpdatedAt: Date, token: String) async throws -> CloudOutsiderRecord {
        let body: [String: Any] = [
            "name": outsider.name, "gender": outsider.gender,
            "contact_preference": outsider.contactPreference, "contact_detail": outsider.contactDetail
        ]
        return try await updateCloudRecord(table: "outsiders", id: outsider.syncID, body: body, expectedUpdatedAt: expectedUpdatedAt, token: token)
    }

    private func updateCloudCourtBooking(
        _ booking: CourtBooking,
        expectedUpdatedAt: Date,
        token: String
    ) async throws -> CloudCourtRecord {
        let body: [String: Any] = [
            "week_start": booking.weekStart.map { Self.dateOnlyFormatter.string(from: $0) } ?? NSNull(),
            "day_of_week": booking.dayOfWeek,
            "start_time": Self.isoFormatter.string(from: booking.effectiveStartTime),
            "end_time": Self.isoFormatter.string(from: booking.effectiveEndTime),
            "venue": booking.venue,
            "court_number": booking.courtNumber
        ]
        return try await updateCloudRecord(
            table: "court_bookings",
            id: booking.syncID,
            body: body,
            expectedUpdatedAt: expectedUpdatedAt,
            token: token
        )
    }

    private func updateCloudSocialSession(
        _ social: SocialSession,
        expectedUpdatedAt: Date,
        token: String
    ) async throws -> CloudSocialRecord {
        let body: [String: Any] = [
            "title": social.title,
            "week_start": Self.dateOnlyFormatter.string(from: social.weekStart),
            "day_of_week": social.dayOfWeek,
            "start_time": Self.isoFormatter.string(from: social.effectiveStartTime),
            "end_time": Self.isoFormatter.string(from: social.effectiveEndTime),
            "venue": social.venue,
            "status": social.status,
            "are_courts_booked": social.areCourtsBooked,
            "court_numbers": social.courtNumbers,
            "shuttlecock_cost": social.shuttlecockCost,
            "court_cost": social.courtCost
        ]
        return try await updateCloudRecord(
            table: "social_sessions",
            id: social.syncID,
            body: body,
            expectedUpdatedAt: expectedUpdatedAt,
            token: token
        )
    }

    private func insertCloudStudent(_ student: Student, token: String) async throws -> CloudStudentRecord {
        try await insertCloudRecord(
            table: "students",
            body: [
                "id": student.syncID.uuidString,
                "workspace_id": SupabaseConfiguration.workspaceID.uuidString,
                "name": student.name,
                "gender": student.gender,
                "contact_preference": student.contactPreference,
                "contact_detail": student.contactDetail,
                "sessions_demand": student.sessionsDemand,
                "is_hidden": student.isHidden,
                "created_at": Self.isoFormatter.string(from: student.createdAt)
            ],
            token: token
        )
    }

    private func insertCloudOutsider(_ outsider: Outsider, token: String) async throws -> CloudOutsiderRecord {
        try await insertCloudRecord(
            table: "outsiders",
            body: [
                "id": outsider.syncID.uuidString,
                "workspace_id": SupabaseConfiguration.workspaceID.uuidString,
                "name": outsider.name,
                "gender": outsider.gender,
                "contact_preference": outsider.contactPreference,
                "contact_detail": outsider.contactDetail,
                "created_at": Self.isoFormatter.string(from: outsider.createdAt)
            ],
            token: token
        )
    }

    private func insertCloudSession(_ session: CoachingSession, token: String) async throws -> CloudSessionRecord {
        try await insertCloudRecord(
            table: "coaching_sessions",
            body: [
                "id": session.syncID.uuidString,
                "workspace_id": SupabaseConfiguration.workspaceID.uuidString,
                "week_start": session.weekStart.map { Self.dateOnlyFormatter.string(from: $0) } ?? NSNull(),
                "day_of_week": session.dayOfWeek,
                "start_time": Self.isoFormatter.string(from: session.effectiveStartTime),
                "end_time": Self.isoFormatter.string(from: session.effectiveEndTime),
                "venue": session.venue,
                "status": session.status,
                "court_number": session.courtNumber,
                "session_fee": session.sessionFee,
                "session_description": session.sessionDescription ?? NSNull(),
                "created_at": Self.isoFormatter.string(from: session.createdAt)
            ],
            token: token
        )
    }

    private func insertCloudCourtBooking(_ booking: CourtBooking, token: String) async throws -> CloudCourtRecord {
        try await insertCloudRecord(
            table: "court_bookings",
            body: [
                "id": booking.syncID.uuidString,
                "workspace_id": SupabaseConfiguration.workspaceID.uuidString,
                "week_start": booking.weekStart.map { Self.dateOnlyFormatter.string(from: $0) } ?? NSNull(),
                "day_of_week": booking.dayOfWeek,
                "start_time": Self.isoFormatter.string(from: booking.effectiveStartTime),
                "end_time": Self.isoFormatter.string(from: booking.effectiveEndTime),
                "venue": booking.venue,
                "court_number": booking.courtNumber,
                "created_at": Self.isoFormatter.string(from: booking.createdAt)
            ],
            token: token
        )
    }

    private func insertCloudSocialSession(_ social: SocialSession, token: String) async throws -> CloudSocialRecord {
        try await insertCloudRecord(
            table: "social_sessions",
            body: [
                "id": social.syncID.uuidString,
                "workspace_id": SupabaseConfiguration.workspaceID.uuidString,
                "title": social.title,
                "week_start": Self.dateOnlyFormatter.string(from: social.weekStart),
                "day_of_week": social.dayOfWeek,
                "start_time": Self.isoFormatter.string(from: social.effectiveStartTime),
                "end_time": Self.isoFormatter.string(from: social.effectiveEndTime),
                "venue": social.venue,
                "status": social.status,
                "are_courts_booked": social.areCourtsBooked,
                "court_numbers": social.courtNumbers,
                "shuttlecock_cost": social.shuttlecockCost,
                "court_cost": social.courtCost,
                "created_at": Self.isoFormatter.string(from: social.createdAt)
            ],
            token: token
        )
    }

    private func insertCloudRecord<Record: Decodable>(
        table: String,
        body: [String: Any],
        token: String
    ) async throws -> Record {
        let data = try await send(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/\(table)"),
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: body),
            token: token,
            prefer: "return=representation"
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        guard let created = try decoder.decode([Record].self, from: data).first else {
            throw SupabaseCloudError.invalidResponse
        }
        return created
    }

    private func softDeleteCloudRecord(
        table: String,
        id: UUID,
        expectedUpdatedAt: Date,
        token: String
    ) async throws {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)"),
            URLQueryItem(name: "deleted_at", value: "is.null"),
            URLQueryItem(name: "updated_at", value: "gte.\(Self.isoFormatter.string(from: expectedUpdatedAt.addingTimeInterval(-0.001)))"),
            URLQueryItem(name: "updated_at", value: "lte.\(Self.isoFormatter.string(from: expectedUpdatedAt.addingTimeInterval(0.001)))")
        ]
        let data = try await send(
            url: components.url!,
            method: "PATCH",
            body: try JSONSerialization.data(withJSONObject: [
                "deleted_at": Self.isoFormatter.string(from: .now)
            ]),
            token: token,
            prefer: "return=representation"
        )
        guard !(try JSONDecoder().decode([CloudID].self, from: data)).isEmpty else {
            throw SupabaseCloudError.conflict
        }
    }

    private func updateCloudRecord<Record: Decodable>(
        table: String,
        id: UUID,
        body: [String: Any],
        expectedUpdatedAt: Date,
        token: String
    ) async throws -> Record {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)"),
            URLQueryItem(name: "updated_at", value: "gte.\(Self.isoFormatter.string(from: expectedUpdatedAt.addingTimeInterval(-0.001)))"),
            URLQueryItem(name: "updated_at", value: "lte.\(Self.isoFormatter.string(from: expectedUpdatedAt.addingTimeInterval(0.001)))")
        ]
        let data = try await send(
            url: components.url!, method: "PATCH",
            body: try JSONSerialization.data(withJSONObject: body), token: token,
            prefer: "return=representation"
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        guard let updated = try decoder.decode([Record].self, from: data).first else {
            throw SupabaseCloudError.conflict
        }
        return updated
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Australia/Perth")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func fetchCourtRecords(token: String) async throws -> [CloudCourtRecord] {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/court_bookings"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,week_start,day_of_week,start_time,end_time,venue,court_number,created_at,updated_at,deleted_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)")
        ]
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        return try decoder.decode([CloudCourtRecord].self, from: data)
    }

    private func fetchSocialRecords(token: String) async throws -> [CloudSocialRecord] {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/social_sessions"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,title,week_start,day_of_week,start_time,end_time,venue,status,are_courts_booked,court_numbers,shuttlecock_cost,court_cost,created_at,updated_at,deleted_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)")
        ]
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        return try decoder.decode([CloudSocialRecord].self, from: data)
    }

    private func fetchOutsiderRecords(token: String) async throws -> [CloudOutsiderRecord] {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/outsiders"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,name,gender,contact_preference,contact_detail,created_at,updated_at,deleted_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)")
        ]
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        return try decoder.decode([CloudOutsiderRecord].self, from: data)
    }

    private func fetchAttendanceRecords(token: String) async throws -> [CloudAttendanceRecord] {
        let data = try await fetchRelationData(
            table: "social_attendance",
            select: "id,social_session_id,student_id,outsider_id,status,payment_status,created_at,updated_at",
            token: token
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        return try decoder.decode([CloudAttendanceRecord].self, from: data)
    }

    private func fetchHiddenWeekRecords(token: String) async throws -> [CloudHiddenWeekRecord] {
        let data = try await fetchRelationData(
            table: "student_hidden_weeks",
            select: "student_id,week_start,created_at",
            token: token
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        return try decoder.decode([CloudHiddenWeekRecord].self, from: data)
    }

    private func fetchCoachingSessionStudentLinks(token: String) async throws -> [CloudSessionStudentLink] {
        let data = try await fetchRelationData(
            table: "coaching_session_students",
            select: "session_id,student_id",
            token: token
        )
        return try JSONDecoder().decode([CloudSessionStudentLink].self, from: data)
    }

    private func fetchSocialSessionStudentLinks(token: String) async throws -> [CloudSessionStudentLink] {
        let data = try await fetchRelationData(
            table: "social_session_students",
            select: "session_id,student_id",
            token: token
        )
        return try JSONDecoder().decode([CloudSessionStudentLink].self, from: data)
    }

    private func fetchHiddenPersonRecords(token: String) async throws -> [CloudHiddenPersonRecord] {
        let data = try await fetchRelationData(
            table: "social_hidden_people",
            select: "id,social_session_id,student_id,outsider_id,created_at",
            token: token
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        return try decoder.decode([CloudHiddenPersonRecord].self, from: data)
    }

    private func fetchRelationData(table: String, select: String, token: String) async throws -> Data {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "select", value: select)]
        return try await send(url: components.url!, method: "GET", body: nil, token: token)
    }

    private func replaceCloudHiddenWeeks(
        for student: Student,
        token: String
    ) async throws {
        try await deleteCloudRows(
            table: "student_hidden_weeks",
            filters: [URLQueryItem(name: "student_id", value: "eq.\(student.syncID.uuidString)")],
            token: token
        )
        let rows = (student.hiddenWeeks ?? []).map { hiddenWeek in
            [
                "student_id": student.syncID.uuidString,
                "week_start": Self.dateOnlyFormatter.string(from: hiddenWeek.weekStart),
                "created_at": Self.isoFormatter.string(from: hiddenWeek.createdAt)
            ]
        }
        try await insertCloudRows(table: "student_hidden_weeks", rows: rows, token: token)
    }

    private func replaceCloudStudents(for session: CoachingSession, token: String) async throws {
        try await deleteCloudRows(
            table: "coaching_session_students",
            filters: [URLQueryItem(name: "session_id", value: "eq.\(session.syncID.uuidString)")],
            token: token
        )
        let rows = session.studentList.map { student in
            [
                "session_id": session.syncID.uuidString,
                "student_id": student.syncID.uuidString
            ]
        }
        try await insertCloudRows(table: "coaching_session_students", rows: rows, token: token)
    }

    private func apply(_ cloud: CloudSessionRecord, to session: CoachingSession) {
        session.weekStart = cloud.weekStart
        session.dayOfWeek = cloud.dayOfWeek
        session.startTime = cloud.startTime
        session.endTime = cloud.endTime
        session.venue = cloud.venue
        session.status = cloud.status
        session.courtNumber = cloud.courtNumber
        session.sessionFee = cloud.sessionFee
        session.sessionDescription = cloud.sessionDescription
        session.updatedAt = cloud.updatedAt
        session.lastSyncedAt = cloud.updatedAt
    }

    private func makeLocalSession(
        from cloud: CloudSessionRecord,
        students: [Student]
    ) -> CoachingSession {
        let session = CoachingSession(
            weekStart: cloud.weekStart,
            dayOfWeek: Weekday(rawValue: cloud.dayOfWeek) ?? .monday,
            startTime: cloud.startTime,
            endTime: cloud.endTime,
            venue: Venue(rawValue: cloud.venue) ?? .pbaMalaga,
            status: SessionStatus(rawValue: cloud.status) ?? .unscheduled,
            courtNumber: cloud.courtNumber,
            sessionFee: cloud.sessionFee,
            sessionDescription: cloud.sessionDescription,
            students: students,
            createdAt: cloud.createdAt,
            syncID: cloud.id
        )
        apply(cloud, to: session)
        return session
    }

    private func fetchCurrentSession(id: UUID, token: String) async throws -> CloudSessionRecord {
        try await fetchCloudRecord(
            table: "coaching_sessions",
            select: "id,week_start,day_of_week,start_time,end_time,venue,status,court_number,session_fee,session_description,created_at,updated_at,deleted_at",
            id: id,
            token: token
        )
    }

    private func cleanupCloudRelationships(forSessionID id: UUID, token: String) async throws {
        try await deleteCloudRows(
            table: "coaching_session_students",
            filters: [URLQueryItem(name: "session_id", value: "eq.\(id.uuidString)")],
            token: token
        )
    }

    private func apply(_ cloud: CloudCourtRecord, to booking: CourtBooking) {
        booking.weekStart = cloud.weekStart
        booking.dayOfWeek = cloud.dayOfWeek
        booking.startTime = cloud.startTime
        booking.endTime = cloud.endTime
        booking.venue = cloud.venue
        booking.courtNumber = cloud.courtNumber
        booking.updatedAt = cloud.updatedAt
        booking.lastSyncedAt = cloud.updatedAt
    }

    private func makeLocalCourtBooking(from cloud: CloudCourtRecord) -> CourtBooking {
        let booking = CourtBooking(
            weekStart: cloud.weekStart,
            dayOfWeek: Weekday(rawValue: cloud.dayOfWeek) ?? .monday,
            startTime: cloud.startTime,
            endTime: cloud.endTime,
            venue: Venue(rawValue: cloud.venue) ?? .pbaMalaga,
            courtNumber: cloud.courtNumber,
            createdAt: cloud.createdAt,
            syncID: cloud.id
        )
        apply(cloud, to: booking)
        return booking
    }

    private func apply(_ cloud: CloudSocialRecord, to social: SocialSession) {
        social.title = cloud.title
        social.weekStart = cloud.weekStart
        social.dayOfWeek = cloud.dayOfWeek
        social.startTime = cloud.startTime
        social.endTime = cloud.endTime
        social.venue = cloud.venue
        social.status = cloud.status
        social.areCourtsBooked = cloud.areCourtsBooked
        social.courtNumbers = cloud.courtNumbers
        social.shuttlecockCost = cloud.shuttlecockCost
        social.courtCost = cloud.courtCost
        social.updatedAt = cloud.updatedAt
        social.lastSyncedAt = cloud.updatedAt
    }

    private func makeLocalSocialSession(
        from cloud: CloudSocialRecord,
        students: [Student]
    ) -> SocialSession {
        let social = SocialSession(
            title: cloud.title,
            weekStart: cloud.weekStart,
            dayOfWeek: Weekday(rawValue: cloud.dayOfWeek) ?? .monday,
            startTime: cloud.startTime,
            endTime: cloud.endTime,
            venue: Venue(rawValue: cloud.venue) ?? .pbaMalaga,
            status: SocialSessionStatus(rawValue: cloud.status) ?? .planned,
            areCourtsBooked: cloud.areCourtsBooked,
            courtNumbers: cloud.courtNumbers,
            shuttlecockCost: cloud.shuttlecockCost,
            courtCost: cloud.courtCost,
            students: students,
            createdAt: cloud.createdAt,
            syncID: cloud.id
        )
        apply(cloud, to: social)
        return social
    }

    private func replaceCloudRelationships(for social: SocialSession, token: String) async throws {
        try await cleanupCloudRelationships(forSocialID: social.syncID, token: token)

        let studentRows = social.studentList.map { student in
            [
                "session_id": social.syncID.uuidString,
                "student_id": student.syncID.uuidString
            ]
        }
        try await insertCloudRows(table: "social_session_students", rows: studentRows, token: token)

        let hiddenRows = social.hiddenPersonList.compactMap { person -> [String: Any]? in
            var row: [String: Any] = [
                "id": person.syncID.uuidString,
                "social_session_id": social.syncID.uuidString,
                "created_at": Self.isoFormatter.string(from: person.createdAt)
            ]
            if let student = person.student {
                row["student_id"] = student.syncID.uuidString
            } else if let outsider = person.outsider {
                row["outsider_id"] = outsider.syncID.uuidString
            } else {
                return nil
            }
            return row
        }
        try await insertCloudRows(table: "social_hidden_people", rows: hiddenRows, token: token)

        let attendanceRows = social.attendanceList.compactMap { attendance -> [String: Any]? in
            var row: [String: Any] = [
                "id": attendance.syncID.uuidString,
                "social_session_id": social.syncID.uuidString,
                "status": attendance.status,
                "payment_status": attendance.paymentStatus,
                "created_at": Self.isoFormatter.string(from: attendance.createdAt)
            ]
            if let student = attendance.student {
                row["student_id"] = student.syncID.uuidString
            } else if let outsider = attendance.outsider {
                row["outsider_id"] = outsider.syncID.uuidString
            } else {
                return nil
            }
            return row
        }
        try await insertCloudRows(table: "social_attendance", rows: attendanceRows, token: token)
    }

    private func stampSocialChildren(_ social: SocialSession, parentTimestamp: Date) {
        for hiddenPerson in social.hiddenPersonList {
            hiddenPerson.updatedAt = parentTimestamp
            hiddenPerson.lastSyncedAt = parentTimestamp
        }
        for attendance in social.attendanceList {
            attendance.updatedAt = parentTimestamp
            attendance.lastSyncedAt = parentTimestamp
        }
    }

    private func applyCloudRelationships(
        to social: SocialSession,
        studentIDs: Set<UUID>,
        hiddenPeople: [CloudHiddenPersonRecord],
        attendances: [CloudAttendanceRecord],
        studentsByID: [UUID: Student],
        outsidersByID: [UUID: Outsider],
        in context: ModelContext,
        parentTimestamp: Date
    ) throws {
        let students = studentIDs.compactMap { studentsByID[$0] }
        guard students.count == studentIDs.count else { throw SupabaseCloudError.invalidResponse }

        for hiddenPerson in social.hiddenPersonList {
            context.delete(hiddenPerson)
        }
        for attendance in social.attendanceList {
            context.delete(attendance)
        }

        var localHiddenPeople: [SocialHiddenPerson] = []
        for record in hiddenPeople {
            let hiddenPerson: SocialHiddenPerson
            if let studentID = record.studentID, let student = studentsByID[studentID] {
                hiddenPerson = SocialHiddenPerson(
                    student: student,
                    createdAt: record.createdAt,
                    syncID: record.id
                )
            } else if let outsiderID = record.outsiderID, let outsider = outsidersByID[outsiderID] {
                hiddenPerson = SocialHiddenPerson(
                    outsider: outsider,
                    createdAt: record.createdAt,
                    syncID: record.id
                )
            } else {
                throw SupabaseCloudError.invalidResponse
            }
            hiddenPerson.session = social
            hiddenPerson.updatedAt = parentTimestamp
            hiddenPerson.lastSyncedAt = parentTimestamp
            context.insert(hiddenPerson)
            localHiddenPeople.append(hiddenPerson)
        }

        var localAttendances: [SocialAttendance] = []
        for record in attendances {
            let student = record.studentID.flatMap { studentsByID[$0] }
            let outsider = record.outsiderID.flatMap { outsidersByID[$0] }
            guard (student != nil) != (outsider != nil) else {
                throw SupabaseCloudError.invalidResponse
            }
            let attendance = SocialAttendance(
                student: student,
                outsider: outsider,
                status: SessionStatus(rawValue: record.status) ?? .unscheduled,
                paymentStatus: SocialPaymentStatus(rawValue: record.paymentStatus) ?? .unpaid,
                createdAt: record.createdAt,
                syncID: record.id
            )
            attendance.session = social
            attendance.status = record.status
            attendance.paymentStatus = record.paymentStatus
            attendance.updatedAt = record.updatedAt
            attendance.lastSyncedAt = record.updatedAt
            context.insert(attendance)
            localAttendances.append(attendance)
        }

        social.studentList = students
        social.legacyHiddenStudentList = []
        social.legacyHiddenOutsiderList = []
        social.hiddenPersonList = localHiddenPeople
        social.attendanceList = localAttendances
    }

    private func fetchCurrentSocial(id: UUID, token: String) async throws -> CloudSocialRecord {
        try await fetchCloudRecord(
            table: "social_sessions",
            select: "id,title,week_start,day_of_week,start_time,end_time,venue,status,are_courts_booked,court_numbers,shuttlecock_cost,court_cost,created_at,updated_at,deleted_at",
            id: id,
            token: token
        )
    }

    private func cleanupCloudRelationships(forSocialID id: UUID, token: String) async throws {
        try await deleteCloudRows(
            table: "social_session_students",
            filters: [URLQueryItem(name: "session_id", value: "eq.\(id.uuidString)")],
            token: token
        )
        for table in ["social_hidden_people", "social_attendance"] {
            try await deleteCloudRows(
                table: table,
                filters: [URLQueryItem(name: "social_session_id", value: "eq.\(id.uuidString)")],
                token: token
            )
        }
    }

    private func applyCloudHiddenWeeks(
        _ records: [CloudHiddenWeekRecord],
        to student: Student,
        in context: ModelContext,
        parentTimestamp: Date
    ) {
        for hiddenWeek in student.hiddenWeeks ?? [] {
            context.delete(hiddenWeek)
        }
        for record in records {
            let hiddenWeek = StudentHiddenWeek(
                student: student,
                weekStart: record.weekStart,
                createdAt: record.createdAt
            )
            hiddenWeek.updatedAt = parentTimestamp
            hiddenWeek.lastSyncedAt = parentTimestamp
            context.insert(hiddenWeek)
        }
    }

    private func apply(_ cloud: CloudStudentRecord, to student: Student) {
        student.name = cloud.name
        student.gender = cloud.gender
        student.contactPreference = cloud.contactPreference
        student.contactDetail = cloud.contactDetail
        student.sessionsDemand = cloud.sessionsDemand
        student.isHidden = cloud.isHidden
        student.updatedAt = cloud.updatedAt
        student.lastSyncedAt = cloud.updatedAt
    }

    private func apply(_ cloud: CloudOutsiderRecord, to outsider: Outsider) {
        outsider.name = cloud.name
        outsider.gender = cloud.gender
        outsider.contactPreference = cloud.contactPreference
        outsider.contactDetail = cloud.contactDetail
        outsider.updatedAt = cloud.updatedAt
        outsider.lastSyncedAt = cloud.updatedAt
    }

    private func makeLocalStudent(from cloud: CloudStudentRecord) -> Student {
        let student = Student(
            name: cloud.name,
            gender: cloud.gender,
            contactPreference: ContactPreference(rawValue: cloud.contactPreference) ?? .instagram,
            contactDetail: cloud.contactDetail,
            sessionsDemand: cloud.sessionsDemand,
            createdAt: cloud.createdAt,
            syncID: cloud.id
        )
        apply(cloud, to: student)
        return student
    }

    private func makeLocalOutsider(from cloud: CloudOutsiderRecord) -> Outsider {
        let outsider = Outsider(
            name: cloud.name,
            gender: cloud.gender,
            contactPreference: ContactPreference(rawValue: cloud.contactPreference) ?? .instagram,
            contactDetail: cloud.contactDetail,
            createdAt: cloud.createdAt,
            syncID: cloud.id
        )
        apply(cloud, to: outsider)
        return outsider
    }

    private func cleanupCloudRelationships(forStudentID id: UUID, token: String) async throws {
        for table in ["coaching_session_students", "social_session_students", "student_hidden_weeks", "social_hidden_people", "social_attendance"] {
            try await deleteCloudRows(
                table: table,
                filters: [URLQueryItem(name: "student_id", value: "eq.\(id.uuidString)")],
                token: token
            )
        }
    }

    private func cleanupCloudRelationships(forOutsiderID id: UUID, token: String) async throws {
        for table in ["social_hidden_people", "social_attendance"] {
            try await deleteCloudRows(
                table: table,
                filters: [URLQueryItem(name: "outsider_id", value: "eq.\(id.uuidString)")],
                token: token
            )
        }
    }

    private func deleteLocalStudent(_ student: Student, in context: ModelContext) throws {
        let studentID = student.persistentModelID
        for session in try context.fetch(FetchDescriptor<CoachingSession>()) {
            session.studentList.removeAll { $0.persistentModelID == studentID }
        }
        for social in try context.fetch(FetchDescriptor<SocialSession>()) {
            social.studentList.removeAll { $0.persistentModelID == studentID }
            social.legacyHiddenStudentList.removeAll { $0.persistentModelID == studentID }
        }
        for attendance in try context.fetch(FetchDescriptor<SocialAttendance>())
        where attendance.student?.persistentModelID == studentID {
            context.delete(attendance)
        }
        for hiddenPerson in try context.fetch(FetchDescriptor<SocialHiddenPerson>())
        where hiddenPerson.student?.persistentModelID == studentID {
            context.delete(hiddenPerson)
        }
        for hiddenWeek in student.hiddenWeeks ?? [] {
            context.delete(hiddenWeek)
        }
        context.delete(student)
    }

    private func deleteLocalOutsider(_ outsider: Outsider, in context: ModelContext) throws {
        let outsiderID = outsider.persistentModelID
        for social in try context.fetch(FetchDescriptor<SocialSession>()) {
            social.legacyHiddenOutsiderList.removeAll { $0.persistentModelID == outsiderID }
        }
        for attendance in try context.fetch(FetchDescriptor<SocialAttendance>())
        where attendance.outsider?.persistentModelID == outsiderID {
            context.delete(attendance)
        }
        for hiddenPerson in try context.fetch(FetchDescriptor<SocialHiddenPerson>())
        where hiddenPerson.outsider?.persistentModelID == outsiderID {
            context.delete(hiddenPerson)
        }
        context.delete(outsider)
    }

    private func removeOrphanedSocialChildren(in context: ModelContext) throws {
        SyncTimestamping.isApplyingRemoteChange = true
        defer { SyncTimestamping.isApplyingRemoteChange = false }
        for attendance in try context.fetch(FetchDescriptor<SocialAttendance>())
        where attendance.student == nil && attendance.outsider == nil {
            context.delete(attendance)
        }
        for hiddenPerson in try context.fetch(FetchDescriptor<SocialHiddenPerson>())
        where hiddenPerson.student == nil && hiddenPerson.outsider == nil {
            context.delete(hiddenPerson)
        }
    }

    private func fetchCurrentStudent(id: UUID, token: String) async throws -> CloudStudentRecord {
        try await fetchCloudRecord(
            table: "students",
            select: "id,name,gender,contact_preference,contact_detail,sessions_demand,is_hidden,created_at,updated_at,deleted_at",
            id: id,
            token: token
        )
    }

    private func deleteCloudRows(
        table: String,
        filters: [URLQueryItem],
        token: String
    ) async throws {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = filters
        _ = try await send(
            url: components.url!,
            method: "DELETE",
            body: nil,
            token: token,
            prefer: "return=minimal"
        )
    }

    private func insertCloudRows(
        table: String,
        rows: [[String: Any]],
        token: String
    ) async throws {
        guard !rows.isEmpty else { return }
        _ = try await send(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/\(table)"),
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: rows),
            token: token,
            prefer: "resolution=ignore-duplicates,return=minimal"
        )
    }

    private func fetchCloudRecord<Record: Decodable>(
        table: String,
        select: String,
        id: UUID,
        token: String
    ) async throws -> Record {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: select),
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)")
        ]
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        guard let record = try decoder.decode([Record].self, from: data).first else {
            throw SupabaseCloudError.invalidResponse
        }
        return record
    }

    private func send(
        url: URL,
        method: String,
        body: Data?,
        authenticated: Bool = true,
        token: String? = nil,
        prefer: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfiguration.publishableKey, forHTTPHeaderField: "apikey")
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseCloudError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SupabaseCloudError.requestFailed(message)
        }
        return data
    }
}

struct SyncRunResult: Equatable {
    let pushed: Int
    let pulled: Int
    let conflicts: Int
    let skipped: Int
    let cloudOnly: Int

    static let zero = SyncRunResult(pushed: 0, pulled: 0, conflicts: 0, skipped: 0, cloudOnly: 0)

    var needsAttention: Bool {
        conflicts > 0 || skipped > 0 || cloudOnly > 0
    }

    var summary: String {
        if needsAttention {
            return "Sync needs attention: \(conflicts) conflicts, \(skipped) unmatched local, \(cloudOnly) unmatched cloud."
        }
        if pushed == 0 && pulled == 0 {
            return "Cloud data is up to date."
        }
        return "Sync complete: \(pushed) uploaded, \(pulled) downloaded."
    }

    func adding(_ other: SyncRunResult) -> SyncRunResult {
        SyncRunResult(
            pushed: pushed + other.pushed,
            pulled: pulled + other.pulled,
            conflicts: conflicts + other.conflicts,
            skipped: skipped + other.skipped,
            cloudOnly: cloudOnly + other.cloudOnly
        )
    }
}

private struct SupabaseSyncLedger: Codable, Equatable {
    private static let defaultsKey = "SupabaseCloud.syncLedger.v1"

    var students: [String: Date] = [:]
    var outsiders: [String: Date] = [:]
    var coachingSessions: [String: Date] = [:]
    var courtBookings: [String: Date] = [:]
    var socialSessions: [String: Date] = [:]

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let ledger = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return ledger
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func key(for id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

private extension CoachingSession {
    var effectiveStartTime: Date {
        effectiveDate(using: startTime)
    }

    var effectiveEndTime: Date {
        effectiveDate(using: endTime)
    }

    private func effectiveDate(using time: Date) -> Date {
        guard let weekStart else { return time }
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: max(dayOfWeek - 1, 0), to: weekStart) ?? weekStart
        let components = calendar.dateComponents([.hour, .minute, .second], from: time)
        return calendar.date(
            bySettingHour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: components.second ?? 0,
            of: day
        ) ?? time
    }
}

private extension CourtBooking {
    var effectiveStartTime: Date {
        effectiveDate(using: startTime)
    }

    var effectiveEndTime: Date {
        effectiveDate(using: endTime)
    }

    private func effectiveDate(using time: Date) -> Date {
        guard let weekStart else { return time }
        return time.applyingSyncWeek(weekStart, dayOfWeek: dayOfWeek)
    }
}

private extension SocialSession {
    var effectiveStartTime: Date {
        startTime.applyingSyncWeek(weekStart, dayOfWeek: dayOfWeek)
    }

    var effectiveEndTime: Date {
        endTime.applyingSyncWeek(weekStart, dayOfWeek: dayOfWeek)
    }
}

private extension SocialHiddenPerson {
    var syncParticipantKey: SocialPersonSyncKey? {
        if let student { return .student(student.syncID) }
        if let outsider { return .outsider(outsider.syncID) }
        return nil
    }
}

private extension SocialAttendance {
    var syncParticipantKey: SocialPersonSyncKey? {
        if let student { return .student(student.syncID) }
        if let outsider { return .outsider(outsider.syncID) }
        return nil
    }

    var syncValue: SocialAttendanceSyncValue? {
        syncParticipantKey.map {
            SocialAttendanceSyncValue(participant: $0, status: status, paymentStatus: paymentStatus)
        }
    }
}

private struct CloudID: Decodable {
    let id: UUID
}

private enum SocialPersonSyncKey: Hashable {
    case student(UUID)
    case outsider(UUID)
}

private struct SocialAttendanceSyncValue: Hashable {
    let participant: SocialPersonSyncKey
    let status: String
    let paymentStatus: String
}

private struct CloudStudentRecord: Decodable {
    let id: UUID
    let name: String
    let gender: String
    let contactPreference: String
    let contactDetail: String
    let sessionsDemand: Int
    let isHidden: Bool
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case gender
        case contactPreference = "contact_preference"
        case contactDetail = "contact_detail"
        case sessionsDemand = "sessions_demand"
        case isHidden = "is_hidden"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    func matchesPayload(of student: Student) -> Bool {
        name == student.name &&
            gender == student.gender &&
            contactPreference == student.contactPreference &&
            contactDetail == student.contactDetail &&
            sessionsDemand == student.sessionsDemand &&
            isHidden == student.isHidden
    }
}

private struct CloudOutsiderRecord: Decodable {
    let id: UUID
    let name: String
    let gender: String
    let contactPreference: String
    let contactDetail: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, gender
        case contactPreference = "contact_preference"
        case contactDetail = "contact_detail"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    func matchesPayload(of outsider: Outsider) -> Bool {
        name == outsider.name &&
            gender == outsider.gender &&
            contactPreference == outsider.contactPreference &&
            contactDetail == outsider.contactDetail
    }
}

private struct CloudAttendanceRecord: Decodable {
    let id: UUID
    let socialSessionID: UUID
    let studentID: UUID?
    let outsiderID: UUID?
    let status: String
    let paymentStatus: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case socialSessionID = "social_session_id"
        case studentID = "student_id"
        case outsiderID = "outsider_id"
        case status
        case paymentStatus = "payment_status"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var participantKey: SocialPersonSyncKey? {
        if let studentID { return .student(studentID) }
        if let outsiderID { return .outsider(outsiderID) }
        return nil
    }

    var syncValue: SocialAttendanceSyncValue? {
        participantKey.map {
            SocialAttendanceSyncValue(participant: $0, status: status, paymentStatus: paymentStatus)
        }
    }
}

private struct CloudHiddenPersonRecord: Decodable {
    let id: UUID
    let socialSessionID: UUID
    let studentID: UUID?
    let outsiderID: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case socialSessionID = "social_session_id"
        case studentID = "student_id"
        case outsiderID = "outsider_id"
        case createdAt = "created_at"
    }

    var participantKey: SocialPersonSyncKey? {
        if let studentID { return .student(studentID) }
        if let outsiderID { return .outsider(outsiderID) }
        return nil
    }
}

private struct CloudHiddenWeekRecord: Decodable {
    let studentID: UUID
    let weekStart: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case studentID = "student_id"
        case weekStart = "week_start"
        case createdAt = "created_at"
    }
}

private struct CloudSessionStudentLink: Decodable {
    let sessionID: UUID
    let studentID: UUID

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case studentID = "student_id"
    }
}

private struct CloudSessionRecord: Decodable {
    let id: UUID
    let weekStart: Date?
    let dayOfWeek: Int
    let startTime: Date
    let endTime: Date
    let venue: String
    let status: String
    let courtNumber: String
    let sessionFee: Double
    let sessionDescription: String?
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case weekStart = "week_start"
        case dayOfWeek = "day_of_week"
        case startTime = "start_time"
        case endTime = "end_time"
        case venue
        case status
        case courtNumber = "court_number"
        case sessionFee = "session_fee"
        case sessionDescription = "session_description"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    func matches(_ session: CoachingSession) -> Bool {
        dayOfWeek == session.dayOfWeek &&
            sameWeek(as: session.weekStart) &&
            startTime.syncMinutes == session.startTime.syncMinutes &&
            endTime.syncMinutes == session.endTime.syncMinutes &&
            venue == session.venue &&
            status == session.status &&
            courtNumber == session.courtNumber
    }

    func matchesPayload(of session: CoachingSession) -> Bool {
        matches(session) &&
            abs(sessionFee - session.sessionFee) < 0.005 &&
            sessionDescription == session.sessionDescription
    }

    private func sameWeek(as localWeekStart: Date?) -> Bool {
        guard let weekStart, let localWeekStart else { return weekStart == nil && localWeekStart == nil }
        return Calendar.current.isDate(weekStart, inSameDayAs: localWeekStart)
    }
}

private extension Date {
    var syncMinutes: Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: self)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    func applyingSyncWeek(_ weekStart: Date, dayOfWeek: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: max(dayOfWeek - 1, 0), to: weekStart) ?? weekStart
        let components = calendar.dateComponents([.hour, .minute, .second], from: self)
        return calendar.date(
            bySettingHour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: components.second ?? 0,
            of: day
        ) ?? self
    }
}

private struct CloudCourtRecord: Decodable {
    let id: UUID
    let weekStart: Date?
    let dayOfWeek: Int
    let startTime: Date
    let endTime: Date
    let venue: String
    let courtNumber: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case weekStart = "week_start"
        case dayOfWeek = "day_of_week"
        case startTime = "start_time"
        case endTime = "end_time"
        case venue
        case courtNumber = "court_number"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    func matches(_ booking: CourtBooking) -> Bool {
        dayOfWeek == booking.dayOfWeek &&
            sameSyncWeek(weekStart, booking.weekStart) &&
            startTime.syncMinutes == booking.startTime.syncMinutes &&
            endTime.syncMinutes == booking.endTime.syncMinutes &&
            venue == booking.venue &&
            courtNumber == booking.courtNumber
    }

    func matchesPayload(of booking: CourtBooking) -> Bool {
        matches(booking)
    }
}

private struct CloudSocialRecord: Decodable {
    let id: UUID
    let title: String
    let weekStart: Date
    let dayOfWeek: Int
    let startTime: Date
    let endTime: Date
    let venue: String
    let status: String
    let areCourtsBooked: Bool
    let courtNumbers: String
    let shuttlecockCost: Double
    let courtCost: Double
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case weekStart = "week_start"
        case dayOfWeek = "day_of_week"
        case startTime = "start_time"
        case endTime = "end_time"
        case venue
        case status
        case areCourtsBooked = "are_courts_booked"
        case courtNumbers = "court_numbers"
        case shuttlecockCost = "shuttlecock_cost"
        case courtCost = "court_cost"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    func matches(_ social: SocialSession) -> Bool {
        title == social.title &&
            Calendar.current.isDate(weekStart, inSameDayAs: social.weekStart) &&
            dayOfWeek == social.dayOfWeek &&
            startTime.syncMinutes == social.startTime.syncMinutes &&
            endTime.syncMinutes == social.endTime.syncMinutes &&
            venue == social.venue
    }

    func matchesPayload(of social: SocialSession) -> Bool {
        matches(social) &&
            status == social.status &&
            areCourtsBooked == social.areCourtsBooked &&
            courtNumbers == social.courtNumbers &&
            abs(shuttlecockCost - social.shuttlecockCost) < 0.005 &&
            abs(courtCost - social.courtCost) < 0.005
    }
}

private func sameSyncWeek(_ first: Date?, _ second: Date?) -> Bool {
    guard let first, let second else { return first == nil && second == nil }
    return Calendar.current.isDate(first, inSameDayAs: second)
}

private extension JSONDecoder.DateDecodingStrategy {
    static let supabaseTimestamp: Self = .custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.calendar = Calendar(identifier: .gregorian)
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        if let date = dateOnlyFormatter.date(from: value) { return date }
        throw DecodingError.dataCorruptedError(
            in: try decoder.singleValueContainer(),
            debugDescription: "Invalid Supabase timestamp"
        )
    }
}

private struct AuthSession: Decodable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private enum SupabaseCloudError: LocalizedError {
    case notSignedIn
    case workspaceUnavailable
    case invalidResponse
    case requestFailed(String)
    case conflict

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Supabase first."
        case .workspaceUnavailable:
            return "This Supabase account does not have access to the CoachPlanner workspace."
        case .invalidResponse:
            return "Supabase returned an invalid response."
        case .requestFailed(let message):
            return "Supabase request failed: \(message)"
        case .conflict:
            return "The cloud record changed before the local update could be applied."
        }
    }
}

private struct SupabaseKeychain {
    private let service = "com.matthewchew.CoachPlanner.supabase"

    func write(_ value: String, key: String) {
        let data = Data(value.utf8)
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
