import Combine
import Foundation
import OSLog
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
    @Published private(set) var conflicts: [SyncConflict] = []
    @Published private(set) var conflictDetailsLastCheckedAt: Date?
    @Published private(set) var resolvingConflictID: String?
    private(set) var deferredChanges = CloudSyncScope()

    private let keychain = SupabaseKeychain()
    private let urlSession: URLSession
    private let defaults: UserDefaults
    private var accessToken: String?
    private var syncLedger: SupabaseSyncLedger
    private var requestCount = 0
    private var activeScope: CloudSyncScope?
    private var needsDependencyRecovery = false
    private var tokenRefreshTask: Task<String, Error>?
    private var authGeneration = 0
    private var syncingAuthGeneration: Int?
    private var fetchedConflictRows: [String: [[String: Any]]] = [:]
    private var conflictResolutionSnapshots: [String: ConflictResolutionSnapshot] = [:]
    private static let logger = Logger(subsystem: "com.matthewchew.CoachPlanner", category: "SupabaseSync")

    private init(urlSession: URLSession = .shared, defaults: UserDefaults = .standard, restoreSession: Bool = true) {
        self.urlSession = urlSession
        self.defaults = defaults
        syncLedger = SupabaseSyncLedger.load(from: defaults)
        accessToken = restoreSession ? keychain.read("access_token") : nil
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
        authGeneration += 1
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        accessToken = nil
        isSignedIn = false
        lastError = nil
        lastSyncResult = nil
        clearConflictReports()
        keychain.delete("access_token")
        keychain.delete("refresh_token")
    }

    func syncAll(in context: ModelContext) async {
        await sync(scope: nil, in: context)
    }

    func syncChanges(_ scope: CloudSyncScope, in context: ModelContext) async {
        guard !scope.isEmpty else { return }
        await sync(scope: scope, in: context)
    }

    private func sync(scope: CloudSyncScope?, in context: ModelContext) async {
        guard !isSyncing else { return }
        isSyncing = true
        syncingAuthGeneration = authGeneration
        activeScope = scope
        deferredChanges = CloudSyncScope()
        needsDependencyRecovery = false
        requestCount = 0
        fetchedConflictRows = [:]
        let startedAt = Date()
        lastSyncResult = nil
        let autosaveWasEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer {
            context.autosaveEnabled = autosaveWasEnabled
            isSyncing = false
            syncingAuthGeneration = nil
            activeScope = nil
            Self.logger.info("Sync finished in \(Date().timeIntervalSince(startedAt), privacy: .public)s; requests: \(self.requestCount, privacy: .public); succeeded: \(self.lastError == nil, privacy: .public)")
        }

        lastError = nil
        do {
            if let scope {
                activeScope = try includingUnsyncedDependencies(scope, in: context)
            }
            let token = try await realtimeAccessToken()
            // RLS can hide records after membership is revoked. Verify access
            // before treating any absent row as a deletion, even in scoped runs.
            try await verifyWorkspaceAccess(token: token)
        } catch {
            lastError = error.localizedDescription
            return
        }

        var combined = SyncRunResult.zero

        await syncStudentsAndOutsiders(in: context)
        guard lastError == nil, let peopleResult = lastSyncResult else {
            lastSyncResult = nil
            return
        }
        combined = combined.adding(peopleResult)

        await syncCourtsSocialsAndAttendance(in: context)
        if needsDependencyRecovery {
            if let partialResult = lastSyncResult { combined = combined.adding(partialResult) }
            // A notification can arrive before the related person's notification.
            // Reconcile dependencies using complete downloads before retrying parents.
            activeScope = nil
            needsDependencyRecovery = false
            await syncStudentsAndOutsiders(in: context)
            guard lastError == nil, let dependenciesResult = lastSyncResult else {
                lastSyncResult = nil
                return
            }
            combined = combined.adding(dependenciesResult)
            await syncCourtsSocialsAndAttendance(in: context)
        }
        guard lastError == nil, let socialResult = lastSyncResult else {
            lastSyncResult = nil
            return
        }
        combined = combined.adding(socialResult)

        await syncCoachingSessions(in: context)
        if needsDependencyRecovery {
            activeScope = nil
            needsDependencyRecovery = false
            await syncStudentsAndOutsiders(in: context)
            guard lastError == nil, let dependenciesResult = lastSyncResult else {
                lastSyncResult = nil
                return
            }
            combined = combined.adding(dependenciesResult)
            await syncCoachingSessions(in: context)
        }
        guard lastError == nil, let sessionResult = lastSyncResult else {
            lastSyncResult = nil
            return
        }
        combined = combined.adding(sessionResult)
        lastSyncResult = combined
        syncLedger.save(to: defaults)
        if scope == nil { conflictDetailsLastCheckedAt = Date() }
    }

    private func syncCoachingSessions(in context: ModelContext) async {
        lastError = nil
        do {
            guard let accessToken else { throw SupabaseCloudError.notSignedIn }
            let localSessions = try context.fetch(FetchDescriptor<CoachingSession>())
                .filter { activeScope?.coachingSessions.contains($0.syncID) ?? true }
            let initialRevisions = Dictionary(uniqueKeysWithValues: localSessions.map { ($0.syncID, revision(of: $0)) })
            async let sessionsRequest = fetchSessionRecords(token: accessToken)
            async let linksRequest = fetchCoachingSessionStudentLinks(token: accessToken)
            let (cloudSessions, cloudLinks) = try await (sessionsRequest, linksRequest)
            let localStudents = try context.fetch(FetchDescriptor<Student>()).filter { !$0.isDeleted }
            let studentByID = localStudents.reduce(into: [UUID: Student]()) { $0[$1.syncID] = $1 }
            guard cloudLinks.allSatisfy({ studentByID[$0.studentID] != nil }) else {
                needsDependencyRecovery = activeScope != nil
                throw SupabaseCloudError.invalidResponse
            }
            let cloudStudentIDsBySession = Dictionary(grouping: cloudLinks, by: \.sessionID)
                .mapValues { Set($0.map(\.studentID)) }
            var remainingCloud = Dictionary(uniqueKeysWithValues: cloudSessions.map { ($0.id, $0) })
            try await deleteCloudRows(
                table: "coaching_session_students", column: "session_id",
                ids: Set(cloudSessions.filter { $0.deletedAt != nil }.map(\.id))
                    .intersection(cloudLinks.map(\.sessionID)), token: accessToken
            )
            var nextLedger = unscopedLedger(syncLedger.coachingSessions, ids: activeScope?.coachingSessions)
            var pushed = 0
            var pulled = 0
            var conflicts = 0
            let skipped = 0
            var cloudOnly = 0
            var reportedIDs: Set<UUID> = []

            for local in localSessions {
                let ledgerKey = SupabaseSyncLedger.key(for: local.syncID)
                guard !local.isDeleted, local.modelContext != nil,
                      initialRevisions[local.syncID] == revision(of: local) else {
                    deferLocalEdit(local, table: "coaching_sessions", id: local.syncID)
                    nextLedger[ledgerKey] = syncLedger.coachingSessions[ledgerKey]
                    remainingCloud.removeValue(forKey: local.syncID)
                    continue
                }
                guard let cloud = remainingCloud.removeValue(forKey: local.syncID) else {
                    if local.lastSyncedAt == nil || syncLedger.coachingSessions[ledgerKey] == nil {
                        let sentRevision = revision(of: local)
                        let studentRows = coachingStudentRows(for: local)
                        var created = try await insertCloudSession(local, token: accessToken)
                        recordAcknowledgement(table: "coaching_sessions", id: local.syncID, timestamp: created.updatedAt)
                        if !studentRows.isEmpty {
                            try await replaceCloudStudents(for: local, rows: studentRows, token: accessToken)
                            created = try await fetchCurrentSession(id: local.syncID, token: accessToken)
                        }
                        acknowledge(local, table: "coaching_sessions", id: local.syncID,
                                    sent: sentRevision, current: revision(of: local), serverTimestamp: created.updatedAt)
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
                    SyncTimestamping.isApplyingRemoteChange = true
                    context.delete(local)
                    SyncTimestamping.isApplyingRemoteChange = false
                    pulled += 1
                    continue
                }

                let knownVersion = syncLedger.coachingSessions[ledgerKey]
                let baseline = local.lastSyncedAt ?? knownVersion ?? cloud.updatedAt
                var localChanged = local.updatedAt > baseline || (local.lastSyncedAt == nil && knownVersion != nil)
                if local.lastSyncedAt == nil {
                    local.lastSyncedAt = baseline
                    if knownVersion != nil { local.updatedAt = max(local.updatedAt, baseline.addingTimeInterval(0.002)) }
                }
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
                        reportedIDs.insert(local.syncID)
                        publishConflict(coachingConflict(local: local, cloud: cloud,
                                                        cloudStudentIDs: cloudStudentIDs, studentsByID: studentByID),
                                        localRevision: revision(of: local))
                        nextLedger[ledgerKey] = baseline
                    }
                } else if localChanged {
                    let sentRevision = revision(of: local)
                    let studentRows = coachingStudentRows(for: local)
                    var updated = try await updateCloudSession(local, expectedUpdatedAt: baseline, token: accessToken)
                    recordAcknowledgement(table: "coaching_sessions", id: local.syncID, timestamp: updated.updatedAt)
                    if localStudentIDs != cloudStudentIDs {
                        try await replaceCloudStudents(for: local, rows: studentRows, token: accessToken)
                        updated = try await fetchCurrentSession(id: local.syncID, token: accessToken)
                    }
                    acknowledge(local, table: "coaching_sessions", id: local.syncID,
                                sent: sentRevision, current: revision(of: local), serverTimestamp: updated.updatedAt)
                    nextLedger[ledgerKey] = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
                    let students = cloudStudentIDs.compactMap { id -> Student? in
                        guard let student = studentByID[id], !student.isDeleted, student.modelContext != nil else { return nil }
                        return student
                    }
                    guard students.count == cloudStudentIDs.count else {
                        needsDependencyRecovery = activeScope != nil
                        throw SupabaseCloudError.invalidResponse
                    }
                    SyncTimestamping.isApplyingRemoteChange = true
                    apply(cloud, to: local)
                    local.studentList = students
                    SyncTimestamping.isApplyingRemoteChange = false
                    nextLedger[ledgerKey] = cloud.updatedAt
                    pulled += 1
                } else {
                    nextLedger[ledgerKey] = cloud.updatedAt
                }
            }

            for cloud in remainingCloud.values {
                guard cloud.deletedAt == nil else { continue }
                let ledgerKey = SupabaseSyncLedger.key(for: cloud.id)
                if let baseline = syncLedger.coachingSessions[ledgerKey] {
                    if cloud.updatedAt > baseline.addingTimeInterval(0.001) {
                        conflicts += 1
                        reportedIDs.insert(cloud.id)
                        publishConflict(deletionConflict(
                            table: "coaching_sessions", id: cloud.id, entityName: "Coaching session",
                            title: sessionConflictTitle(
                                start: cloud.weekStart.map { cloud.startTime.applyingSyncWeek($0, dayOfWeek: cloud.dayOfWeek) } ?? cloud.startTime,
                                venue: cloud.venue
                            ),
                            cloudUpdatedAt: cloud.updatedAt, baseline: baseline
                        ))
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
                    let students = studentIDs.compactMap { id -> Student? in
                        guard let student = studentByID[id], !student.isDeleted, student.modelContext != nil else { return nil }
                        return student
                    }
                    guard students.count == studentIDs.count else {
                        needsDependencyRecovery = activeScope != nil
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
            syncLedger.save(to: defaults)
            finishConflictChecks(table: "coaching_sessions",
                                 checkedIDs: Set(localSessions.map(\.syncID)).union(cloudSessions.map(\.id)),
                                 reportedIDs: reportedIDs, requestedIDs: activeScope?.coachingSessions)
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
                .filter { activeScope?.students.contains($0.syncID) ?? true }
            let localOutsiders = try context.fetch(FetchDescriptor<Outsider>())
                .filter { activeScope?.outsiders.contains($0.syncID) ?? true }
            let initialStudentRevisions = Dictionary(uniqueKeysWithValues: localStudents.map { ($0.syncID, revision(of: $0)) })
            let initialOutsiderRevisions = Dictionary(uniqueKeysWithValues: localOutsiders.map { ($0.syncID, revision(of: $0)) })
            async let studentsRequest = fetchStudentRecords(token: accessToken)
            async let outsidersRequest = fetchOutsiderRecords(token: accessToken)
            async let hiddenWeeksRequest = fetchHiddenWeekRecords(token: accessToken)
            let (cloudStudents, cloudOutsiders, cloudHiddenWeeks) = try await (studentsRequest, outsidersRequest, hiddenWeeksRequest)
            try await cleanupCloudRelationships(
                forStudentIDs: Set(cloudStudents.filter { $0.deletedAt != nil }.map(\.id)), token: accessToken
            )
            try await cleanupCloudRelationships(
                forOutsiderIDs: Set(cloudOutsiders.filter { $0.deletedAt != nil }.map(\.id)), token: accessToken
            )
            var remainingCloudStudents = Dictionary(uniqueKeysWithValues: cloudStudents.map { ($0.id, $0) })
            var remainingCloudOutsiders = Dictionary(uniqueKeysWithValues: cloudOutsiders.map { ($0.id, $0) })
            let hiddenWeeksByStudent = Dictionary(grouping: cloudHiddenWeeks, by: \.studentID)
            var nextStudentLedger = unscopedLedger(syncLedger.students, ids: activeScope?.students)
            var nextOutsiderLedger = unscopedLedger(syncLedger.outsiders, ids: activeScope?.outsiders)
            var reportedStudentIDs: Set<UUID> = []
            var reportedOutsiderIDs: Set<UUID> = []
            var pushed = 0
            var pulled = 0
            var conflicts = 0
            let skipped = 0
            var cloudOnly = 0

            for student in localStudents {
                let ledgerKey = SupabaseSyncLedger.key(for: student.syncID)
                guard !student.isDeleted, student.modelContext != nil,
                      initialStudentRevisions[student.syncID] == revision(of: student) else {
                    deferLocalEdit(student, table: "students", id: student.syncID)
                    nextStudentLedger[ledgerKey] = syncLedger.students[ledgerKey]
                    remainingCloudStudents.removeValue(forKey: student.syncID)
                    continue
                }
                guard let cloud = remainingCloudStudents.removeValue(forKey: student.syncID) else {
                    if student.lastSyncedAt == nil || syncLedger.students[ledgerKey] == nil {
                        let sentRevision = revision(of: student)
                        let hiddenRows = hiddenWeekRows(for: student)
                        var created = try await insertCloudStudent(student, token: accessToken)
                        recordAcknowledgement(table: "students", id: student.syncID, timestamp: created.updatedAt)
                        if !hiddenRows.isEmpty {
                            try await replaceCloudHiddenWeeks(for: student, rows: hiddenRows, token: accessToken)
                            created = try await fetchCurrentStudent(id: student.syncID, token: accessToken)
                        }
                        if acknowledge(student, table: "students", id: student.syncID,
                                       sent: sentRevision, current: revision(of: student), serverTimestamp: created.updatedAt) {
                            for hiddenWeek in student.hiddenWeeks ?? [] {
                                hiddenWeek.updatedAt = created.updatedAt
                                hiddenWeek.lastSyncedAt = created.updatedAt
                            }
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
                    SyncTimestamping.isApplyingRemoteChange = true
                    try deleteLocalStudent(student, in: context)
                    SyncTimestamping.isApplyingRemoteChange = false
                    pulled += 1
                    continue
                }

                let knownVersion = syncLedger.students[ledgerKey]
                let baseline = student.lastSyncedAt ?? knownVersion ?? cloud.updatedAt
                var localChanged = student.updatedAt > baseline || (student.lastSyncedAt == nil && knownVersion != nil)
                if student.lastSyncedAt == nil {
                    student.lastSyncedAt = baseline
                    if knownVersion != nil { student.updatedAt = max(student.updatedAt, baseline.addingTimeInterval(0.002)) }
                }
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
                        reportedStudentIDs.insert(student.syncID)
                        publishConflict(studentConflict(local: student, cloud: cloud,
                                                       localHiddenWeeks: localHiddenWeekKeys, cloudHiddenWeeks: cloudHiddenWeekKeys),
                                        localRevision: revision(of: student))
                        nextStudentLedger[ledgerKey] = baseline
                    }
                } else if localChanged {
                    let sentRevision = revision(of: student)
                    let hiddenRows = hiddenWeekRows(for: student)
                    var updated = try await updateCloudStudent(student, expectedUpdatedAt: baseline, token: accessToken)
                    recordAcknowledgement(table: "students", id: student.syncID, timestamp: updated.updatedAt)
                    if localHiddenWeekKeys != cloudHiddenWeekKeys {
                        try await replaceCloudHiddenWeeks(for: student, rows: hiddenRows, token: accessToken)
                        updated = try await fetchCurrentStudent(id: student.syncID, token: accessToken)
                    }
                    if acknowledge(student, table: "students", id: student.syncID,
                                   sent: sentRevision, current: revision(of: student), serverTimestamp: updated.updatedAt) {
                        for hiddenWeek in student.hiddenWeeks ?? [] {
                            hiddenWeek.updatedAt = updated.updatedAt
                            hiddenWeek.lastSyncedAt = updated.updatedAt
                        }
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
                guard cloud.deletedAt == nil else { continue }
                let ledgerKey = SupabaseSyncLedger.key(for: cloud.id)
                if let baseline = syncLedger.students[ledgerKey] {
                    if cloud.updatedAt > baseline.addingTimeInterval(0.001) {
                        conflicts += 1
                        reportedStudentIDs.insert(cloud.id)
                        let incoming = try await personDeletionRelationships(id: cloud.id, isStudent: true, token: accessToken)
                        publishConflict(deletionConflict(table: "students", id: cloud.id, entityName: "Student",
                                                        title: cloud.name, cloudUpdatedAt: cloud.updatedAt, baseline: baseline),
                                        additionalRelationships: incoming,
                                        incomingParents: try incomingParentRevisions(incoming, in: context))
                        cloudOnly += 1
                        nextStudentLedger[ledgerKey] = baseline
                    } else {
                        try await softDeleteCloudRecord(
                            table: "students",
                            id: cloud.id,
                            expectedUpdatedAt: baseline,
                            token: accessToken
                        )
                        try await cleanupCloudRelationships(forStudentIDs: [cloud.id], token: accessToken)
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
                guard !outsider.isDeleted, outsider.modelContext != nil,
                      initialOutsiderRevisions[outsider.syncID] == revision(of: outsider) else {
                    deferLocalEdit(outsider, table: "outsiders", id: outsider.syncID)
                    nextOutsiderLedger[ledgerKey] = syncLedger.outsiders[ledgerKey]
                    remainingCloudOutsiders.removeValue(forKey: outsider.syncID)
                    continue
                }
                guard let cloud = remainingCloudOutsiders.removeValue(forKey: outsider.syncID) else {
                    if outsider.lastSyncedAt == nil || syncLedger.outsiders[ledgerKey] == nil {
                        let sentRevision = revision(of: outsider)
                        let created = try await insertCloudOutsider(outsider, token: accessToken)
                        acknowledge(outsider, table: "outsiders", id: outsider.syncID,
                                    sent: sentRevision, current: revision(of: outsider), serverTimestamp: created.updatedAt)
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
                    SyncTimestamping.isApplyingRemoteChange = true
                    try deleteLocalOutsider(outsider, in: context)
                    SyncTimestamping.isApplyingRemoteChange = false
                    pulled += 1
                    continue
                }

                let knownVersion = syncLedger.outsiders[ledgerKey]
                let baseline = outsider.lastSyncedAt ?? knownVersion ?? cloud.updatedAt
                var localChanged = outsider.updatedAt > baseline || (outsider.lastSyncedAt == nil && knownVersion != nil)
                if outsider.lastSyncedAt == nil {
                    outsider.lastSyncedAt = baseline
                    if knownVersion != nil { outsider.updatedAt = max(outsider.updatedAt, baseline.addingTimeInterval(0.002)) }
                }
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
                        reportedOutsiderIDs.insert(outsider.syncID)
                        publishConflict(outsiderConflict(local: outsider, cloud: cloud), localRevision: revision(of: outsider))
                        nextOutsiderLedger[ledgerKey] = baseline
                    }
                } else if localChanged {
                    let sentRevision = revision(of: outsider)
                    let updated = try await updateCloudOutsider(outsider, expectedUpdatedAt: baseline, token: accessToken)
                    acknowledge(outsider, table: "outsiders", id: outsider.syncID,
                                sent: sentRevision, current: revision(of: outsider), serverTimestamp: updated.updatedAt)
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
                guard cloud.deletedAt == nil else { continue }
                let ledgerKey = SupabaseSyncLedger.key(for: cloud.id)
                if let baseline = syncLedger.outsiders[ledgerKey] {
                    if cloud.updatedAt > baseline.addingTimeInterval(0.001) {
                        conflicts += 1
                        reportedOutsiderIDs.insert(cloud.id)
                        let incoming = try await personDeletionRelationships(id: cloud.id, isStudent: false, token: accessToken)
                        publishConflict(deletionConflict(table: "outsiders", id: cloud.id, entityName: "Outsider",
                                                        title: cloud.name, cloudUpdatedAt: cloud.updatedAt, baseline: baseline),
                                        additionalRelationships: incoming,
                                        incomingParents: try incomingParentRevisions(incoming, in: context))
                        cloudOnly += 1
                        nextOutsiderLedger[ledgerKey] = baseline
                    } else {
                        try await softDeleteCloudRecord(
                            table: "outsiders",
                            id: cloud.id,
                            expectedUpdatedAt: baseline,
                            token: accessToken
                        )
                        try await cleanupCloudRelationships(forOutsiderIDs: [cloud.id], token: accessToken)
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
            syncLedger.save(to: defaults)
            finishConflictChecks(table: "students",
                                 checkedIDs: Set(localStudents.map(\.syncID)).union(cloudStudents.map(\.id)),
                                 reportedIDs: reportedStudentIDs, requestedIDs: activeScope?.students)
            finishConflictChecks(table: "outsiders",
                                 checkedIDs: Set(localOutsiders.map(\.syncID)).union(cloudOutsiders.map(\.id)),
                                 reportedIDs: reportedOutsiderIDs, requestedIDs: activeScope?.outsiders)
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
        lastSyncResult = nil
        do {
            guard let accessToken else { throw SupabaseCloudError.notSignedIn }
            let courtResult = try await syncCourtBookings(in: context, token: accessToken)
            lastSyncResult = courtResult
            let socialResult = try await syncSocialSessions(in: context, token: accessToken)
            lastSyncResult = courtResult.adding(socialResult)
        } catch {
            SyncTimestamping.isApplyingRemoteChange = false
            lastError = error.localizedDescription
        }
    }

    private func syncCourtBookings(in context: ModelContext, token: String) async throws -> SyncRunResult {
        let localBookings = try context.fetch(FetchDescriptor<CourtBooking>())
            .filter { activeScope?.courtBookings.contains($0.syncID) ?? true }
        let initialRevisions = Dictionary(uniqueKeysWithValues: localBookings.map { ($0.syncID, revision(of: $0)) })
        let cloudBookings = try await fetchCourtRecords(token: token)
        var remainingCloud = Dictionary(uniqueKeysWithValues: cloudBookings.map { ($0.id, $0) })
        var nextLedger = unscopedLedger(syncLedger.courtBookings, ids: activeScope?.courtBookings)
        var reportedIDs: Set<UUID> = []
        var pushed = 0
        var pulled = 0
        var conflicts = 0
        var cloudOnly = 0

        for booking in localBookings {
            let ledgerKey = SupabaseSyncLedger.key(for: booking.syncID)
            guard !booking.isDeleted, booking.modelContext != nil,
                  initialRevisions[booking.syncID] == revision(of: booking) else {
                deferLocalEdit(booking, table: "court_bookings", id: booking.syncID)
                nextLedger[ledgerKey] = syncLedger.courtBookings[ledgerKey]
                remainingCloud.removeValue(forKey: booking.syncID)
                continue
            }
            guard let cloud = remainingCloud.removeValue(forKey: booking.syncID) else {
                if booking.lastSyncedAt == nil || syncLedger.courtBookings[ledgerKey] == nil {
                    let sentRevision = revision(of: booking)
                    let created = try await insertCloudCourtBooking(booking, token: token)
                    acknowledge(booking, table: "court_bookings", id: booking.syncID,
                                sent: sentRevision, current: revision(of: booking), serverTimestamp: created.updatedAt)
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

            let knownVersion = syncLedger.courtBookings[ledgerKey]
            let baseline = booking.lastSyncedAt ?? knownVersion ?? cloud.updatedAt
            var localChanged = booking.updatedAt > baseline || (booking.lastSyncedAt == nil && knownVersion != nil)
            if booking.lastSyncedAt == nil {
                booking.lastSyncedAt = baseline
                if knownVersion != nil { booking.updatedAt = max(booking.updatedAt, baseline.addingTimeInterval(0.002)) }
            }
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
                    reportedIDs.insert(booking.syncID)
                    publishConflict(courtConflict(local: booking, cloud: cloud), localRevision: revision(of: booking))
                    nextLedger[ledgerKey] = baseline
                }
            } else if localChanged {
                let sentRevision = revision(of: booking)
                let updated = try await updateCloudCourtBooking(
                    booking,
                    expectedUpdatedAt: baseline,
                    token: token
                )
                acknowledge(booking, table: "court_bookings", id: booking.syncID,
                            sent: sentRevision, current: revision(of: booking), serverTimestamp: updated.updatedAt)
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
                    reportedIDs.insert(cloud.id)
                    publishConflict(deletionConflict(
                        table: "court_bookings", id: cloud.id, entityName: "Court booking",
                        title: sessionConflictTitle(
                            start: cloud.weekStart.map { cloud.startTime.applyingSyncWeek($0, dayOfWeek: cloud.dayOfWeek) } ?? cloud.startTime,
                            venue: cloud.venue
                        ),
                        cloudUpdatedAt: cloud.updatedAt, baseline: baseline
                    ))
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
        syncLedger.save(to: defaults)
        finishConflictChecks(table: "court_bookings",
                             checkedIDs: Set(localBookings.map(\.syncID)).union(cloudBookings.map(\.id)),
                             reportedIDs: reportedIDs, requestedIDs: activeScope?.courtBookings)
        return SyncRunResult(
            pushed: pushed,
            pulled: pulled,
            conflicts: conflicts,
            skipped: 0,
            cloudOnly: cloudOnly
        )
    }

    private func syncSocialSessions(in context: ModelContext, token: String) async throws -> SyncRunResult {
        try removeOrphanedSocialChildren(in: context, socialIDs: activeScope?.socialSessions)
        let localSocials = try context.fetch(FetchDescriptor<SocialSession>())
            .filter { activeScope?.socialSessions.contains($0.syncID) ?? true }
        let initialRevisions = Dictionary(uniqueKeysWithValues: localSocials.map { ($0.syncID, revision(of: $0)) })
        // Each parent and all its children come from one database snapshot.
        // Independent REST reads can pair a new parent version with old attendance.
        let snapshots = try await fetchSocialSnapshots(token: token)
        let cloudSocials = snapshots.map(\.record)
        let cloudStudentLinks = snapshots.flatMap { $0.relationships.students }
        let cloudHiddenPeople = snapshots.flatMap { $0.relationships.hiddenPeople }
        let cloudAttendances = snapshots.flatMap { $0.relationships.attendances }
        let localStudents = try context.fetch(FetchDescriptor<Student>()).filter { !$0.isDeleted }
        let localOutsiders = try context.fetch(FetchDescriptor<Outsider>()).filter { !$0.isDeleted }
        let knownStudents = Set(localStudents.map(\.syncID))
        let knownOutsiders = Set(localOutsiders.map(\.syncID))
        let relationshipStudents = Set(cloudStudentLinks.map(\.studentID))
            .union(cloudHiddenPeople.compactMap(\.studentID))
            .union(cloudAttendances.compactMap(\.studentID))
        let relationshipOutsiders = Set(cloudHiddenPeople.compactMap(\.outsiderID))
            .union(cloudAttendances.compactMap(\.outsiderID))
        guard relationshipStudents.isSubset(of: knownStudents), relationshipOutsiders.isSubset(of: knownOutsiders) else {
            needsDependencyRecovery = activeScope != nil
            throw SupabaseCloudError.invalidResponse
        }
        // Clean legacy tombstone relationships through the same transaction as
        // normal deletion, never as three independent destructive requests.
        for snapshot in snapshots where snapshot.record.deletedAt != nil &&
            (!snapshot.relationships.students.isEmpty || !snapshot.relationships.hiddenPeople.isEmpty ||
             !snapshot.relationships.attendances.isEmpty) {
            _ = try await writeSocialSnapshot(id: snapshot.id, expected: capturedCloudSnapshot(table: "social_sessions", id: snapshot.id),
                                              replacement: nil, createdAt: nil, token: token)
        }

        let studentsByID = localStudents.reduce(into: [UUID: Student]()) { $0[$1.syncID] = $1 }
        let outsidersByID = localOutsiders.reduce(into: [UUID: Outsider]()) { $0[$1.syncID] = $1 }
        let studentIDsBySocial = Dictionary(grouping: cloudStudentLinks, by: \.sessionID)
            .mapValues { Set($0.map(\.studentID)) }
        let hiddenPeopleBySocial = Dictionary(grouping: cloudHiddenPeople, by: \.socialSessionID)
        let attendancesBySocial = Dictionary(grouping: cloudAttendances, by: \.socialSessionID)
        var remainingCloud = Dictionary(uniqueKeysWithValues: cloudSocials.map { ($0.id, $0) })
        var nextLedger = unscopedLedger(syncLedger.socialSessions, ids: activeScope?.socialSessions)
        var reportedIDs: Set<UUID> = []
        var pushed = 0
        var pulled = 0
        var conflicts = 0
        var cloudOnly = 0

        for social in localSocials {
            let ledgerKey = SupabaseSyncLedger.key(for: social.syncID)
            guard !social.isDeleted, social.modelContext != nil,
                  initialRevisions[social.syncID] == revision(of: social) else {
                deferLocalEdit(social, table: "social_sessions", id: social.syncID)
                nextLedger[ledgerKey] = syncLedger.socialSessions[ledgerKey]
                remainingCloud.removeValue(forKey: social.syncID)
                continue
            }
            guard let cloud = remainingCloud.removeValue(forKey: social.syncID) else {
                if social.lastSyncedAt == nil || syncLedger.socialSessions[ledgerKey] == nil {
                    let sentRevision = revision(of: social)
                    let replacement = try resolutionReplacement(for: social)
                    recordCreationIntent(table: "social_sessions", id: social.syncID)
                    let created = try await writeSocialSnapshot(id: social.syncID, expected: nil,
                                                               replacement: replacement, createdAt: social.createdAt, token: token)
                    if acknowledge(social, table: "social_sessions", id: social.syncID,
                                   sent: sentRevision, current: revision(of: social), serverTimestamp: created.updatedAt) {
                        stampSocialChildren(social, parentTimestamp: created.updatedAt)
                    }
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
                SyncTimestamping.isApplyingRemoteChange = true
                context.delete(social)
                SyncTimestamping.isApplyingRemoteChange = false
                pulled += 1
                continue
            }

            let knownVersion = syncLedger.socialSessions[ledgerKey]
            let baseline = social.lastSyncedAt ?? knownVersion ?? cloud.updatedAt
            let localChanged = social.updatedAt > baseline || (social.lastSyncedAt == nil && knownVersion != nil)
            if social.lastSyncedAt == nil {
                social.lastSyncedAt = baseline
                if knownVersion != nil { social.updatedAt = max(social.updatedAt, baseline.addingTimeInterval(0.002)) }
            }
            let cloudChanged = cloud.updatedAt > baseline
            let cloudStudentIDs = studentIDsBySocial[social.syncID] ?? []
            let cloudHidden = hiddenPeopleBySocial[social.syncID] ?? []
            let cloudAttendance = attendancesBySocial[social.syncID] ?? []
            let localHiddenKeys = Set(social.hiddenPersonList.compactMap(\.syncParticipantKey))
            let cloudHiddenKeys = Set(cloudHidden.compactMap(\.participantKey))
            let localAttendanceValues = Set(social.attendanceList.compactMap(\.syncValue))
            let cloudAttendanceValues = Set(cloudAttendance.compactMap(\.syncValue))
            let studentsChanged = Set(social.studentList.map(\.syncID)) != cloudStudentIDs
            let hiddenPeopleChanged = localHiddenKeys != cloudHiddenKeys || social.hiddenPersonList.count != cloudHidden.count
            let attendanceChanged = localAttendanceValues != cloudAttendanceValues || social.attendanceList.count != cloudAttendance.count
            let relationshipsMatch = !studentsChanged && !hiddenPeopleChanged && !attendanceChanged
            let payloadsMatch = cloud.matchesPayload(of: social) && relationshipsMatch

            // An old mixed-version cache or an untracked edit is ambiguous.
            // Never turn a clean timestamp + differing values into an upload.
            let ambiguousMismatch = !localChanged && !cloudChanged && !payloadsMatch
            if (localChanged && cloudChanged) || ambiguousMismatch {
                if payloadsMatch {
                    social.updatedAt = cloud.updatedAt
                    social.lastSyncedAt = cloud.updatedAt
                    stampSocialChildren(social, parentTimestamp: cloud.updatedAt)
                    nextLedger[ledgerKey] = cloud.updatedAt
                } else {
                    conflicts += 1
                    reportedIDs.insert(social.syncID)
                    publishConflict(socialConflict(
                        local: social, cloud: cloud, cloudStudentIDs: cloudStudentIDs,
                        cloudHiddenPeople: cloudHidden, cloudAttendances: cloudAttendance,
                        studentsByID: studentsByID, outsidersByID: outsidersByID
                    ), localRevision: revision(of: social))
                    nextLedger[ledgerKey] = baseline
                }
            } else if localChanged {
                let sentRevision = revision(of: social)
                guard let expected = capturedCloudSnapshot(table: "social_sessions", id: social.syncID) else {
                    throw SupabaseCloudError.invalidResponse
                }
                let updated = try await writeSocialSnapshot(id: social.syncID, expected: expected,
                                                           replacement: resolutionReplacement(for: social), createdAt: nil, token: token)
                if acknowledge(social, table: "social_sessions", id: social.syncID,
                               sent: sentRevision, current: revision(of: social), serverTimestamp: updated.updatedAt) {
                    stampSocialChildren(social, parentTimestamp: updated.updatedAt)
                }
                nextLedger[ledgerKey] = updated.updatedAt
                pushed += 1
            } else if cloudChanged {
                SyncTimestamping.isApplyingRemoteChange = true
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
                apply(cloud, to: social)
                SyncTimestamping.isApplyingRemoteChange = false
                nextLedger[ledgerKey] = cloud.updatedAt
                pulled += 1
            } else {
                nextLedger[ledgerKey] = cloud.updatedAt
            }
        }

        for cloud in remainingCloud.values {
            guard cloud.deletedAt == nil else { continue }
            let ledgerKey = SupabaseSyncLedger.key(for: cloud.id)
            if let baseline = syncLedger.socialSessions[ledgerKey] {
                if cloud.updatedAt > baseline.addingTimeInterval(0.001) {
                    conflicts += 1
                    reportedIDs.insert(cloud.id)
                    publishConflict(deletionConflict(
                        table: "social_sessions", id: cloud.id, entityName: "Social session",
                        title: socialConflictTitle(
                            title: cloud.title, start: cloud.startTime.applyingSyncWeek(cloud.weekStart, dayOfWeek: cloud.dayOfWeek),
                            venue: cloud.venue
                        ),
                        cloudUpdatedAt: cloud.updatedAt, baseline: baseline
                    ))
                    cloudOnly += 1
                    nextLedger[ledgerKey] = baseline
                } else {
                    guard let expected = capturedCloudSnapshot(table: "social_sessions", id: cloud.id) else {
                        throw SupabaseCloudError.invalidResponse
                    }
                    _ = try await writeSocialSnapshot(id: cloud.id, expected: expected, replacement: nil, createdAt: nil, token: token)
                    pushed += 1
                }
            } else {
                let studentIDs = studentIDsBySocial[cloud.id] ?? []
                let students = try validateSocialDependencies(
                    studentIDs: studentIDs, hiddenPeople: hiddenPeopleBySocial[cloud.id] ?? [],
                    attendances: attendancesBySocial[cloud.id] ?? [],
                    studentsByID: studentsByID, outsidersByID: outsidersByID
                )
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
        syncLedger.save(to: defaults)
        finishConflictChecks(table: "social_sessions",
                             checkedIDs: Set(localSocials.map(\.syncID)).union(cloudSocials.map(\.id)),
                             reportedIDs: reportedIDs, requestedIDs: activeScope?.socialSessions)
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

    private struct ConflictResolutionSnapshot {
        let localRevision: LocalRevision?
        let cloud: [String: Any]
        let incomingParents: [IncomingParentRevision]
    }

    private struct IncomingParentRevision {
        let table: String
        let id: UUID
        let revision: LocalRevision?
    }

    private static func conflictRelationships(for table: String) -> [(table: String, parent: String)] {
        switch table {
        case "students": return [("student_hidden_weeks", "student_id")]
        case "coaching_sessions": return [("coaching_session_students", "session_id")]
        case "social_sessions": return [("social_session_students", "session_id"),
                                        ("social_hidden_people", "social_session_id"),
                                        ("social_attendance", "social_session_id")]
        default: return []
        }
    }

    private func capturedCloudSnapshot(table: String, id: UUID) -> [String: Any]? {
        guard let record = fetchedConflictRows[table]?.first(where: { UUID(uuidString: $0["id"] as? String ?? "") == id }) else {
            return nil
        }
        var relationships: [String: Any] = [:]
        for child in Self.conflictRelationships(for: table) {
            guard let rows = fetchedConflictRows[child.table] else { return nil }
            relationships[child.table] = rows.filter { UUID(uuidString: $0[child.parent] as? String ?? "") == id }
        }
        return ["record": record, "relationships": relationships]
    }

    private func personDeletionRelationships(id: UUID, isStudent: Bool, token: String) async throws -> [String: Any] {
        let column = isStudent ? "student_id" : "outsider_id"
        let filters = [URLQueryItem(name: column, value: "eq.\(id.uuidString)")]
        var result: [String: Any] = [:]
        if isStudent {
            for table in ["coaching_session_students", "social_session_students"] {
                fetchedConflictRows[table] = []
                let _: [CloudSessionStudentLink] = try await fetchCloudRecords(
                    table: table, select: "session_id,student_id", order: "session_id.asc,student_id.asc",
                    filters: filters, token: token, applyScope: false
                )
                result[table] = fetchedConflictRows[table] ?? []
            }
        }
        fetchedConflictRows["social_hidden_people"] = []
        let _: [CloudHiddenPersonRecord] = try await fetchCloudRecords(
            table: "social_hidden_people", select: "id,social_session_id,student_id,outsider_id,created_at", order: "id.asc",
            filters: filters, token: token, applyScope: false
        )
        result["social_hidden_people"] = fetchedConflictRows["social_hidden_people"] ?? []
        fetchedConflictRows["social_attendance"] = []
        let _: [CloudAttendanceRecord] = try await fetchCloudRecords(
            table: "social_attendance", select: "id,social_session_id,student_id,outsider_id,status,payment_status,created_at,updated_at",
            order: "id.asc", filters: filters, token: token, applyScope: false
        )
        result["social_attendance"] = fetchedConflictRows["social_attendance"] ?? []
        return result
    }

    private func incomingParentRevisions(_ relationships: [String: Any], in context: ModelContext) throws -> [IncomingParentRevision] {
        var coaching: Set<UUID> = []
        var socials: Set<UUID> = []
        for (table, value) in relationships {
            guard let rows = value as? [[String: Any]] else { throw SupabaseCloudError.invalidResponse }
            let column = table == "coaching_session_students" || table == "social_session_students" ? "session_id" : "social_session_id"
            for row in rows {
                guard let id = UUID(uuidString: row[column] as? String ?? "") else { throw SupabaseCloudError.invalidResponse }
                if table == "coaching_session_students" { coaching.insert(id) } else { socials.insert(id) }
            }
        }
        var result: [IncomingParentRevision] = []
        for (table, ids) in [("coaching_sessions", coaching), ("social_sessions", socials)] {
            for id in ids {
                let local = try resolutionModel(table: table, id: id, in: context)
                result.append(IncomingParentRevision(table: table, id: id, revision: local.map { revision(of: $0) }))
            }
        }
        return result
    }

    private func verifyIncomingParents(_ parents: [IncomingParentRevision], in context: ModelContext) throws {
        for parent in parents {
            guard let reviewed = parent.revision,
                  let current = try resolutionModel(table: parent.table, id: parent.id, in: context) else {
                throw ConflictResolutionError.invalidRelationships
            }
            guard revision(of: current) == reviewed else { throw ConflictResolutionError.localChanged }
        }
    }

    /// Resolves only the exact comparison confirmed by the user. The RPC checks
    /// the complete captured cloud snapshot and commits parent/children together.
    /// Normal reconciliation never implicitly chooses a conflict winner.
    func resolveConflict(_ conflict: SyncConflict, choice: SyncConflictChoice, in context: ModelContext) async throws -> String {
        guard !isSyncing else { throw ConflictResolutionError.busy }
        guard conflicts.contains(conflict), let captured = conflictResolutionSnapshots[conflict.id] else {
            throw ConflictResolutionError.stale
        }
        // Do not turn unfinished editor input into an approved overwrite.
        guard !context.hasChanges else { throw ConflictResolutionError.unsavedChanges }
        let original = try resolutionModel(table: conflict.table, id: conflict.recordID, in: context)
        guard original.map({ revision(of: $0) }) == captured.localRevision else {
            throw ConflictResolutionError.localChanged
        }
        if choice == .cloud { try verifyIncomingParents(captured.incomingParents, in: context) }
        let replacement: Any = choice == .device
            ? try original.map { try resolutionReplacement(for: $0) } ?? NSNull() : NSNull()
        isSyncing = true
        resolvingConflictID = conflict.id
        syncingAuthGeneration = authGeneration
        lastError = nil
        let autosaveWasEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer {
            context.autosaveEnabled = autosaveWasEnabled
            resolvingConflictID = nil
            isSyncing = false
            syncingAuthGeneration = nil
        }
        do {
            let token = try await realtimeAccessToken()
            try await verifyWorkspaceAccess(token: token)
            // Authentication and access checks can suspend while an editor saves.
            guard try resolutionModel(table: conflict.table, id: conflict.recordID, in: context)
                .map({ revision(of: $0) }) == captured.localRevision else {
                throw ConflictResolutionError.localChanged
            }
            if choice == .cloud { try verifyIncomingParents(captured.incomingParents, in: context) }
            let data = try await send(
                url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/rpc/resolve_coachplanner_conflict"),
                method: "POST", body: JSONSerialization.data(withJSONObject: [
                    "p_workspace_id": SupabaseConfiguration.workspaceID.uuidString,
                    "p_table": conflict.table, "p_record_id": conflict.recordID.uuidString,
                    "p_expected": captured.cloud, "p_choice": choice.rawValue,
                    "p_replacement": choice == .device ? replacement : NSNull()
                ]), token: token
            )
            guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let row = snapshot["record"] as? [String: Any],
                  UUID(uuidString: row["id"] as? String ?? "") == conflict.recordID,
                  snapshot["relationships"] is [String: Any] else {
                throw SupabaseCloudError.invalidResponse
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .supabaseTimestamp
            let version = try decoder.decode(ResolutionVersion.self, from: JSONSerialization.data(withJSONObject: row))
            // Save any UI changes made during the request with normal timestamping
            // before applying remote values, so they can never be mistaken for a pull.
            if context.hasChanges { try context.save() }
            let current = try resolutionModel(table: conflict.table, id: conflict.recordID, in: context)
            let unchanged = current.map({ revision(of: $0) }) == captured.localRevision
            if choice == .cloud {
                guard unchanged else { throw ConflictResolutionError.localChanged }
                try verifyIncomingParents(captured.incomingParents, in: context)
                do {
                    try applyResolutionSnapshot(snapshot, table: conflict.table, id: conflict.recordID, to: current, in: context)
                    try saveSyncChanges(in: context)
                } catch {
                    // There were no unsaved user edits when the synchronous apply
                    // began; rollback only this failed local resolution.
                    context.rollback()
                    throw error
                }
                recordAcknowledgement(table: conflict.table, id: conflict.recordID, timestamp: version.updatedAt)
            } else {
                // Even if the UI changed during the request, acknowledge only the
                // version that was uploaded and preserve the newer local payload.
                recordAcknowledgement(table: conflict.table, id: conflict.recordID, timestamp: version.updatedAt)
                if let current, let sent = captured.localRevision {
                    _ = acknowledge(current, table: conflict.table, id: conflict.recordID,
                                    sent: sent, current: revision(of: current), serverTimestamp: version.updatedAt)
                    if unchanged, let social = current as? SocialSession {
                        stampSocialChildren(social, parentTimestamp: version.updatedAt)
                    }
                } else if !unchanged {
                    deferChange(table: conflict.table, id: conflict.recordID)
                }
                try saveSyncChanges(in: context)
                if !unchanged {
                    return "The confirmed device version was saved to the cloud. Newer changes on this device were kept; sync again to review their current state."
                }
            }
            conflicts.removeAll { $0.id == conflict.id }
            conflictResolutionSnapshots.removeValue(forKey: conflict.id)
            lastSyncResult = nil
            return choice == .cloud ? "Cloud version applied to this device."
                : captured.localRevision == nil ? "Deletion kept. The cloud record was marked deleted."
                : "Device version saved to the cloud."
        } catch {
            let message = error.localizedDescription
            if message.contains("CP_CONFLICT_STALE") { throw ConflictResolutionError.stale }
            if message.contains("PGRST202") { throw ConflictResolutionError.serverSetupRequired }
            throw error
        }
    }

    private struct ResolutionVersion: Decodable {
        let updatedAt: Date
        enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
    }

    private func resolutionModel(table: String, id: UUID, in context: ModelContext) throws -> (any PersistentModel & SyncTimestamped)? {
        let models: [any PersistentModel & SyncTimestamped]
        switch table {
        case "students": models = try context.fetch(FetchDescriptor<Student>()).filter { $0.syncID == id && !$0.isDeleted }
        case "outsiders": models = try context.fetch(FetchDescriptor<Outsider>()).filter { $0.syncID == id && !$0.isDeleted }
        case "coaching_sessions": models = try context.fetch(FetchDescriptor<CoachingSession>()).filter { $0.syncID == id && !$0.isDeleted }
        case "court_bookings": models = try context.fetch(FetchDescriptor<CourtBooking>()).filter { $0.syncID == id && !$0.isDeleted }
        case "social_sessions": models = try context.fetch(FetchDescriptor<SocialSession>()).filter { $0.syncID == id && !$0.isDeleted }
        default: throw SupabaseCloudError.invalidResponse
        }
        guard models.count <= 1 else { throw SupabaseCloudError.invalidResponse }
        return models.first
    }

    private func revision(of model: any PersistentModel & SyncTimestamped) -> LocalRevision {
        switch model {
        case let value as Student: return revision(of: value)
        case let value as Outsider: return revision(of: value)
        case let value as CoachingSession: return revision(of: value)
        case let value as CourtBooking: return revision(of: value)
        case let value as SocialSession: return revision(of: value)
        default: preconditionFailure("Unsupported conflict record")
        }
    }

    private func resolutionReplacement(for model: any PersistentModel & SyncTimestamped) throws -> [String: Any] {
        let row: [String: Any]
        var relationships: [String: Any] = [:]
        switch model {
        case let value as Student:
            row = ["name": value.name, "gender": value.gender, "contact_preference": value.contactPreference,
                   "contact_detail": value.contactDetail, "sessions_demand": value.sessionsDemand, "is_hidden": value.isHidden]
            relationships["student_hidden_weeks"] = hiddenWeekRows(for: value)
        case let value as Outsider:
            row = ["name": value.name, "gender": value.gender, "contact_preference": value.contactPreference,
                   "contact_detail": value.contactDetail]
        case let value as CoachingSession:
            row = ["week_start": value.weekStart.map { Self.dateOnlyFormatter.string(from: $0) } ?? NSNull(),
                   "day_of_week": value.dayOfWeek, "start_time": Self.isoFormatter.string(from: value.effectiveStartTime),
                   "end_time": Self.isoFormatter.string(from: value.effectiveEndTime), "venue": value.venue,
                   "status": value.status, "court_number": value.courtNumber, "session_fee": value.sessionFee,
                   "session_description": value.sessionDescription ?? NSNull()]
            relationships["coaching_session_students"] = coachingStudentRows(for: value)
        case let value as CourtBooking:
            row = ["week_start": value.weekStart.map { Self.dateOnlyFormatter.string(from: $0) } ?? NSNull(),
                   "day_of_week": value.dayOfWeek, "start_time": Self.isoFormatter.string(from: value.effectiveStartTime),
                   "end_time": Self.isoFormatter.string(from: value.effectiveEndTime), "venue": value.venue,
                   "court_number": value.courtNumber]
        case let value as SocialSession:
            guard value.hiddenPersonList.allSatisfy({ $0.syncParticipantKey != nil }),
                  value.attendanceList.allSatisfy({ $0.syncParticipantKey != nil }) else {
                throw ConflictResolutionError.invalidRelationships
            }
            row = ["title": value.title, "week_start": Self.dateOnlyFormatter.string(from: value.weekStart),
                   "day_of_week": value.dayOfWeek, "start_time": Self.isoFormatter.string(from: value.effectiveStartTime),
                   "end_time": Self.isoFormatter.string(from: value.effectiveEndTime), "venue": value.venue,
                   "status": value.status, "are_courts_booked": value.areCourtsBooked, "court_numbers": value.courtNumbers,
                   "shuttlecock_cost": value.shuttlecockCost, "court_cost": value.courtCost]
            let children = socialRelationshipRows(for: value)
            relationships = ["social_session_students": children.students, "social_hidden_people": children.hiddenPeople,
                             "social_attendance": children.attendances]
        default: throw SupabaseCloudError.invalidResponse
        }
        return ["record": row, "relationships": relationships]
    }

    private func applyResolutionSnapshot(_ snapshot: [String: Any], table: String, id: UUID,
                                         to local: (any PersistentModel & SyncTimestamped)?, in context: ModelContext) throws {
        guard let row = snapshot["record"] as? [String: Any], let relationships = snapshot["relationships"] as? [String: Any],
              row["deleted_at"] == nil || row["deleted_at"] is NSNull else { throw ConflictResolutionError.stale }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
            try decoder.decode(type, from: JSONSerialization.data(withJSONObject: object))
        }
        func studentsFor(_ ids: Set<UUID>) throws -> [Student] {
            let students = try context.fetch(FetchDescriptor<Student>()).filter { ids.contains($0.syncID) && !$0.isDeleted }
            guard Set(students.map(\.syncID)) == ids else { throw ConflictResolutionError.invalidRelationships }
            return students
        }
        switch table {
        case "students":
            let cloud = try decode(CloudStudentRecord.self, row)
            let weeks = try decode([CloudHiddenWeekRecord].self, relationships["student_hidden_weeks"] ?? [])
            let student = (local as? Student) ?? makeLocalStudent(from: cloud)
            if local == nil { context.insert(student) }
            apply(cloud, to: student)
            applyCloudHiddenWeeks(weeks, to: student, in: context, parentTimestamp: cloud.updatedAt)
            if local == nil {
                try restoreIncomingConflictRelationships(relationships, student: student, outsider: nil, in: context)
            }
        case "outsiders":
            let cloud = try decode(CloudOutsiderRecord.self, row)
            let outsider = (local as? Outsider) ?? makeLocalOutsider(from: cloud)
            if local == nil { context.insert(outsider) }
            apply(cloud, to: outsider)
            if local == nil {
                try restoreIncomingConflictRelationships(relationships, student: nil, outsider: outsider, in: context)
            }
        case "coaching_sessions":
            let cloud = try decode(CloudSessionRecord.self, row)
            let links = try decode([CloudSessionStudentLink].self, relationships["coaching_session_students"] ?? [])
            let students = try studentsFor(Set(links.map(\.studentID)))
            let session = (local as? CoachingSession) ?? makeLocalSession(from: cloud, students: students)
            if local == nil { context.insert(session) }
            apply(cloud, to: session)
            session.studentList = students
        case "court_bookings":
            let cloud = try decode(CloudCourtRecord.self, row)
            let booking = (local as? CourtBooking) ?? makeLocalCourtBooking(from: cloud)
            if local == nil { context.insert(booking) }
            apply(cloud, to: booking)
        case "social_sessions":
            let cloud = try decode(CloudSocialRecord.self, row)
            let links = try decode([CloudSessionStudentLink].self, relationships["social_session_students"] ?? [])
            let hidden = try decode([CloudHiddenPersonRecord].self, relationships["social_hidden_people"] ?? [])
            let attendance = try decode([CloudAttendanceRecord].self, relationships["social_attendance"] ?? [])
            let students = try context.fetch(FetchDescriptor<Student>()).filter { !$0.isDeleted }
            let outsiders = try context.fetch(FetchDescriptor<Outsider>()).filter { !$0.isDeleted }
            let studentsByID = students.reduce(into: [UUID: Student]()) { $0[$1.syncID] = $1 }
            let outsidersByID = outsiders.reduce(into: [UUID: Outsider]()) { $0[$1.syncID] = $1 }
            let linked = try validateSocialDependencies(studentIDs: Set(links.map(\.studentID)), hiddenPeople: hidden,
                                                        attendances: attendance, studentsByID: studentsByID, outsidersByID: outsidersByID)
            let social = (local as? SocialSession) ?? makeLocalSocialSession(from: cloud, students: linked)
            if local == nil { context.insert(social) }
            try applyCloudRelationships(to: social, studentIDs: Set(links.map(\.studentID)), hiddenPeople: hidden,
                                        attendances: attendance, studentsByID: studentsByID, outsidersByID: outsidersByID,
                                        in: context, parentTimestamp: cloud.updatedAt)
            apply(cloud, to: social)
        default: throw SupabaseCloudError.invalidResponse
        }
    }

    // Reports describe existing reconciliation decisions; they never choose a
    // winner, write a record, or change conflict detection.
    private func clearConflictReports() {
        conflicts = []
        conflictDetailsLastCheckedAt = nil
        conflictResolutionSnapshots = [:]
        fetchedConflictRows = [:]
    }

    private func publishConflict(_ report: SyncConflict, localRevision: LocalRevision? = nil,
                                 additionalRelationships: [String: Any] = [:], incomingParents: [IncomingParentRevision] = []) {
        if var snapshot = capturedCloudSnapshot(table: report.table, id: report.recordID) {
            var relationships = snapshot["relationships"] as? [String: Any] ?? [:]
            relationships.merge(additionalRelationships) { _, new in new }
            snapshot["relationships"] = relationships
            conflictResolutionSnapshots[report.id] = ConflictResolutionSnapshot(
                localRevision: localRevision, cloud: snapshot, incomingParents: incomingParents
            )
        } else {
            conflictResolutionSnapshots.removeValue(forKey: report.id)
        }
        let incomingLabels = ["coaching_session_students": "Coaching session links",
                              "social_session_students": "Social participant links",
                              "social_hidden_people": "Social visibility entries",
                              "social_attendance": "Social attendance entries"]
        let incomingDifferences = additionalRelationships.keys.sorted().compactMap { table -> SyncConflictDifference? in
            guard let rows = additionalRelationships[table] as? [[String: Any]], !rows.isEmpty else { return nil }
            return SyncConflictDifference(id: "incoming:\(table)", label: incomingLabels[table] ?? table,
                                          localValue: "Removed with this person", cloudValue: "\(rows.count) linked entries")
        }
        let visibleReport = SyncConflict(
            id: report.id, table: report.table, recordID: report.recordID, entityName: report.entityName,
            title: report.title, detectedAt: report.detectedAt, localUpdatedAt: report.localUpdatedAt,
            cloudUpdatedAt: report.cloudUpdatedAt, reason: report.reason,
            differences: report.differences + incomingDifferences
        )
        var updated = conflicts.filter { $0.id != report.id }
        updated.append(visibleReport)
        conflicts = updated.sorted {
            if $0.entityName != $1.entityName { return $0.entityName < $1.entityName }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private func finishConflictChecks(
        table: String, checkedIDs: Set<UUID>, reportedIDs: Set<UUID>, requestedIDs: Set<UUID>?
    ) {
        // Only called after this stage saved successfully. A failed fetch,
        // write, or save leaves its previous reports intact.
        var completedIDs = checkedIDs
        if let requestedIDs {
            completedIDs.formUnion(requestedIDs)
        } else {
            // A complete table download also checks reports for rows which no
            // longer exist on either side.
            completedIDs.formUnion(conflicts.filter { $0.table == table }.map(\.recordID))
        }
        let deferredIDs: Set<UUID>
        switch table {
        case "students": deferredIDs = deferredChanges.students
        case "outsiders": deferredIDs = deferredChanges.outsiders
        case "court_bookings": deferredIDs = deferredChanges.courtBookings
        case "coaching_sessions": deferredIDs = deferredChanges.coachingSessions
        case "social_sessions": deferredIDs = deferredChanges.socialSessions
        default: return
        }
        completedIDs.subtract(deferredIDs)
        conflicts.removeAll {
            $0.table == table && completedIDs.contains($0.recordID) && !reportedIDs.contains($0.recordID)
        }
        let retained = Set(conflicts.map(\.id))
        conflictResolutionSnapshots = conflictResolutionSnapshots.filter { retained.contains($0.key) }
    }

    private func conflictReport(
        table: String, id: UUID, entityName: String, title: String,
        localUpdatedAt: Date?, cloudUpdatedAt: Date?,
        reason: String = "The sync check could not safely choose between the local and cloud versions.",
        differences: [SyncConflictDifference]
    ) -> SyncConflict {
        SyncConflict(
            id: "\(table):\(id.uuidString.lowercased())", table: table, recordID: id,
            entityName: entityName, title: title.isEmpty ? "\(entityName) \(id.uuidString)" : title,
            detectedAt: Date(), localUpdatedAt: localUpdatedAt, cloudUpdatedAt: cloudUpdatedAt,
            reason: reason, differences: differences
        )
    }

    private func deletionConflict(
        table: String, id: UUID, entityName: String, title: String, cloudUpdatedAt: Date, baseline: Date
    ) -> SyncConflict {
        conflictReport(
            table: table, id: id, entityName: entityName, title: title,
            localUpdatedAt: nil, cloudUpdatedAt: cloudUpdatedAt,
            reason: baseline == .distantPast
                ? "A cloud copy exists after an upload whose result was not confirmed. This device no longer has the record, so sync needs a review."
                : "This device no longer has the record, but the cloud copy changed after its last synced version. Automatic deletion was stopped.",
            differences: [SyncConflictDifference(id: "presence", label: "Record availability",
                                                localValue: "Not present on this device", cloudValue: "Present in the cloud")]
        )
    }

    private func conflictField(_ id: String, _ label: String, _ local: String, _ cloud: String) -> SyncConflictDifference? {
        guard local != cloud else { return nil }
        return SyncConflictDifference(id: id, label: label, localValue: local, cloudValue: cloud)
    }

    private func conflictText(_ value: String?) -> String {
        guard let value else { return "Not set" }
        guard !value.isEmpty else { return "Empty" }
        // Keep literal text distinct from the placeholders, including values
        // already beginning with the quotes used for that distinction.
        if value == "Not set" || value == "Empty" || value.hasPrefix("\"") {
            return String(reflecting: value)
        }
        return value
    }

    private func conflictDate(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .omitted) ?? "Not set"
    }

    private func conflictTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func conflictWeekday(_ day: Int) -> String {
        Weekday(rawValue: day)?.name ?? String(day)
    }

    private func conflictAmount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }

    private func sessionConflictTitle(start: Date, venue: String) -> String {
        "\(start.formatted(date: .abbreviated, time: .shortened)) · \(venue)"
    }

    private func socialConflictTitle(title: String, start: Date, venue: String) -> String {
        let session = sessionConflictTitle(start: start, venue: venue)
        return title.isEmpty ? session : "\(title) · \(session)"
    }

    private func studentConflict(
        local: Student, cloud: CloudStudentRecord, localHiddenWeeks: Set<String>, cloudHiddenWeeks: Set<String>
    ) -> SyncConflict {
        var differences = [
            conflictField("name", "Name", conflictText(local.name), conflictText(cloud.name)),
            conflictField("gender", "Gender", conflictText(local.gender), conflictText(cloud.gender)),
            conflictField("contact_preference", "Contact preference", conflictText(local.contactPreference), conflictText(cloud.contactPreference)),
            conflictField("contact_detail", "Contact details", conflictText(local.contactDetail), conflictText(cloud.contactDetail)),
            conflictField("sessions_demand", "Weekly sessions", String(local.sessionsDemand), String(cloud.sessionsDemand)),
            conflictField("is_hidden", "Roster visibility", local.isHidden ? "Hidden" : "Visible", cloud.isHidden ? "Hidden" : "Visible")
        ].compactMap { $0 }
        for week in localHiddenWeeks.symmetricDifference(cloudHiddenWeeks).sorted() {
            let label = Self.dateOnlyFormatter.date(from: week).map { conflictDate($0) } ?? week
            differences.append(SyncConflictDifference(
                id: "hidden_week:\(week)", label: "Week of \(label)",
                localValue: localHiddenWeeks.contains(week) ? "Hidden" : "Visible",
                cloudValue: cloudHiddenWeeks.contains(week) ? "Hidden" : "Visible"
            ))
        }
        return conflictReport(table: "students", id: local.syncID, entityName: "Student",
                              title: local.name.isEmpty ? cloud.name : local.name,
                              localUpdatedAt: local.updatedAt, cloudUpdatedAt: cloud.updatedAt, differences: differences)
    }

    private func outsiderConflict(local: Outsider, cloud: CloudOutsiderRecord) -> SyncConflict {
        conflictReport(table: "outsiders", id: local.syncID, entityName: "Outsider",
                       title: local.name.isEmpty ? cloud.name : local.name,
                       localUpdatedAt: local.updatedAt, cloudUpdatedAt: cloud.updatedAt,
                       differences: [
                        conflictField("name", "Name", conflictText(local.name), conflictText(cloud.name)),
                        conflictField("gender", "Gender", conflictText(local.gender), conflictText(cloud.gender)),
                        conflictField("contact_preference", "Contact preference", conflictText(local.contactPreference), conflictText(cloud.contactPreference)),
                        conflictField("contact_detail", "Contact details", conflictText(local.contactDetail), conflictText(cloud.contactDetail))
                       ].compactMap { $0 })
    }

    private func coachingConflict(
        local: CoachingSession, cloud: CloudSessionRecord, cloudStudentIDs: Set<UUID>, studentsByID: [UUID: Student]
    ) -> SyncConflict {
        var differences = [
            conflictField("week_start", "Week starting", conflictDate(local.weekStart), conflictDate(cloud.weekStart)),
            conflictField("day_of_week", "Day", conflictWeekday(local.dayOfWeek), conflictWeekday(cloud.dayOfWeek)),
            conflictField("start_time", "Start time", conflictTime(local.startTime), conflictTime(cloud.startTime)),
            conflictField("end_time", "End time", conflictTime(local.endTime), conflictTime(cloud.endTime)),
            conflictField("venue", "Venue", conflictText(local.venue), conflictText(cloud.venue)),
            conflictField("status", "Session status", conflictText(local.status), conflictText(cloud.status)),
            conflictField("court_number", "Court", conflictText(local.courtNumber), conflictText(cloud.courtNumber)),
            abs(local.sessionFee - cloud.sessionFee) < 0.005 ? nil
                : conflictField("session_fee", "Session fee", conflictAmount(local.sessionFee), conflictAmount(cloud.sessionFee)),
            conflictField("session_description", "Description", conflictText(local.sessionDescription), conflictText(cloud.sessionDescription))
        ].compactMap { $0 }
        differences += participantDifferences(
            local: Set(local.studentList.map { SocialPersonSyncKey.student($0.syncID) }),
            cloud: Set(cloudStudentIDs.map(SocialPersonSyncKey.student)), label: "Participant", field: "participant",
            localPresent: "Included", cloudPresent: "Included", absent: "Not included",
            studentsByID: studentsByID, outsidersByID: [:]
        )
        return conflictReport(table: "coaching_sessions", id: local.syncID, entityName: "Coaching session",
                              title: sessionConflictTitle(start: local.effectiveStartTime, venue: local.venue),
                              localUpdatedAt: local.updatedAt, cloudUpdatedAt: cloud.updatedAt, differences: differences)
    }

    private func courtConflict(local: CourtBooking, cloud: CloudCourtRecord) -> SyncConflict {
        conflictReport(table: "court_bookings", id: local.syncID, entityName: "Court booking",
                       title: sessionConflictTitle(start: local.effectiveStartTime, venue: local.venue),
                       localUpdatedAt: local.updatedAt, cloudUpdatedAt: cloud.updatedAt,
                       differences: [
                        conflictField("week_start", "Week starting", conflictDate(local.weekStart), conflictDate(cloud.weekStart)),
                        conflictField("day_of_week", "Day", conflictWeekday(local.dayOfWeek), conflictWeekday(cloud.dayOfWeek)),
                        conflictField("start_time", "Start time", conflictTime(local.startTime), conflictTime(cloud.startTime)),
                        conflictField("end_time", "End time", conflictTime(local.endTime), conflictTime(cloud.endTime)),
                        conflictField("venue", "Venue", conflictText(local.venue), conflictText(cloud.venue)),
                        conflictField("court_number", "Court", conflictText(local.courtNumber), conflictText(cloud.courtNumber))
                       ].compactMap { $0 })
    }

    private func socialConflict(
        local: SocialSession, cloud: CloudSocialRecord, cloudStudentIDs: Set<UUID>,
        cloudHiddenPeople: [CloudHiddenPersonRecord], cloudAttendances: [CloudAttendanceRecord],
        studentsByID: [UUID: Student], outsidersByID: [UUID: Outsider]
    ) -> SyncConflict {
        var differences = [
            conflictField("title", "Title", conflictText(local.title), conflictText(cloud.title)),
            conflictField("week_start", "Week starting", conflictDate(local.weekStart), conflictDate(cloud.weekStart)),
            conflictField("day_of_week", "Day", conflictWeekday(local.dayOfWeek), conflictWeekday(cloud.dayOfWeek)),
            conflictField("start_time", "Start time", conflictTime(local.startTime), conflictTime(cloud.startTime)),
            conflictField("end_time", "End time", conflictTime(local.endTime), conflictTime(cloud.endTime)),
            conflictField("venue", "Venue", conflictText(local.venue), conflictText(cloud.venue)),
            conflictField("status", "Session status", conflictText(local.status), conflictText(cloud.status)),
            conflictField("are_courts_booked", "Courts booked", local.areCourtsBooked ? "Yes" : "No", cloud.areCourtsBooked ? "Yes" : "No"),
            conflictField("court_numbers", "Courts", conflictText(local.courtNumbers), conflictText(cloud.courtNumbers)),
            abs(local.shuttlecockCost - cloud.shuttlecockCost) < 0.005 ? nil
                : conflictField("shuttlecock_cost", "Shuttlecock cost", conflictAmount(local.shuttlecockCost), conflictAmount(cloud.shuttlecockCost)),
            abs(local.courtCost - cloud.courtCost) < 0.005 ? nil
                : conflictField("court_cost", "Court cost", conflictAmount(local.courtCost), conflictAmount(cloud.courtCost))
        ].compactMap { $0 }
        differences += participantDifferences(
            local: Set(local.studentList.map { SocialPersonSyncKey.student($0.syncID) }),
            cloud: Set(cloudStudentIDs.map(SocialPersonSyncKey.student)), label: "Participant", field: "participant",
            localPresent: "Included", cloudPresent: "Included", absent: "Not included",
            studentsByID: studentsByID, outsidersByID: outsidersByID
        )
        differences += participantDifferences(
            local: Set(local.hiddenPersonList.compactMap(\.syncParticipantKey)),
            cloud: Set(cloudHiddenPeople.compactMap(\.participantKey)), label: "Visibility", field: "hidden",
            localPresent: "Hidden", cloudPresent: "Hidden", absent: "Visible",
            studentsByID: studentsByID, outsidersByID: outsidersByID
        )
        if let count = conflictField("hidden_count", "Hidden entries", String(local.hiddenPersonList.count), String(cloudHiddenPeople.count)) {
            differences.append(count)
        }
        let localAttendance = Dictionary(grouping: local.attendanceList.compactMap(\.syncValue), by: \.participant)
        let cloudAttendance = Dictionary(grouping: cloudAttendances.compactMap(\.syncValue), by: \.participant)
        let people = Set(localAttendance.keys).union(cloudAttendance.keys).sorted { participantID($0) < participantID($1) }
        for person in people {
            let localValues = localAttendance[person] ?? []
            let cloudValues = cloudAttendance[person] ?? []
            let name = participantName(person, studentsByID: studentsByID, outsidersByID: outsidersByID)
            let id = participantID(person)
            let localStatus = localValues.isEmpty ? "Not attending" : localValues.map(\.status).sorted().joined(separator: ", ")
            let cloudStatus = cloudValues.isEmpty ? "Not attending" : cloudValues.map(\.status).sorted().joined(separator: ", ")
            let localPayment = localValues.isEmpty ? "Not attending" : localValues.map(\.paymentStatus).sorted().joined(separator: ", ")
            let cloudPayment = cloudValues.isEmpty ? "Not attending" : cloudValues.map(\.paymentStatus).sorted().joined(separator: ", ")
            if let status = conflictField("attendance:\(id)", "\(name) · Attendance", localStatus, cloudStatus) {
                differences.append(status)
            }
            if let payment = conflictField("payment:\(id)", "\(name) · Payment", localPayment, cloudPayment) {
                differences.append(payment)
            }
            if localValues.count > 1 || cloudValues.count > 1 {
                // Preserve which payment belongs to which attendance status.
                // Separate sorted columns can hide swapped duplicate entries.
                let localPairs = localValues.map { "\($0.status) · \($0.paymentStatus)" }.sorted().joined(separator: "; ")
                let cloudPairs = cloudValues.map { "\($0.status) · \($0.paymentStatus)" }.sorted().joined(separator: "; ")
                if let pairs = conflictField("attendance_pairs:\(id)", "\(name) · Attendance and payment", localPairs, cloudPairs) {
                    differences.append(pairs)
                }
            }
        }
        if let count = conflictField("attendance_count", "Attendance entries", String(local.attendanceList.count), String(cloudAttendances.count)) {
            differences.append(count)
        }
        return conflictReport(table: "social_sessions", id: local.syncID, entityName: "Social session",
                              title: socialConflictTitle(title: local.title, start: local.effectiveStartTime, venue: local.venue),
                              localUpdatedAt: local.updatedAt, cloudUpdatedAt: cloud.updatedAt, differences: differences)
    }

    private func participantID(_ person: SocialPersonSyncKey) -> String {
        switch person {
        case .student(let id): return "student:\(id.uuidString.lowercased())"
        case .outsider(let id): return "outsider:\(id.uuidString.lowercased())"
        }
    }

    private func participantName(_ person: SocialPersonSyncKey, studentsByID: [UUID: Student], outsidersByID: [UUID: Outsider]) -> String {
        switch person {
        case .student(let id):
            if let name = studentsByID[id]?.name, !name.isEmpty { return name }
            return "Student \(id.uuidString)"
        case .outsider(let id):
            if let name = outsidersByID[id]?.name, !name.isEmpty { return name }
            return "Outsider \(id.uuidString)"
        }
    }

    private func participantDifferences(
        local: Set<SocialPersonSyncKey>, cloud: Set<SocialPersonSyncKey>, label: String, field: String,
        localPresent: String, cloudPresent: String, absent: String,
        studentsByID: [UUID: Student], outsidersByID: [UUID: Outsider]
    ) -> [SyncConflictDifference] {
        local.symmetricDifference(cloud).sorted { participantID($0) < participantID($1) }.map { person in
            SyncConflictDifference(
                id: "\(field):\(participantID(person))",
                label: "\(participantName(person, studentsByID: studentsByID, outsidersByID: outsidersByID)) · \(label)",
                localValue: local.contains(person) ? localPresent : absent,
                cloudValue: cloud.contains(person) ? cloudPresent : absent
            )
        }
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
        try Task.checkCancellation()
        accessToken = session.accessToken
        keychain.write(session.accessToken, key: "access_token")
        if let rotatedRefreshToken = session.refreshToken {
            keychain.write(rotatedRefreshToken, key: "refresh_token")
        }
        isSignedIn = true
    }

    /// Shared by REST and Realtime so concurrent reconnects do not rotate the
    /// refresh token twice. Tokens close to expiry are renewed before use.
    func realtimeAccessToken() async throws -> String {
        if let accessToken, Self.tokenIsUsable(accessToken) { return accessToken }
        if let tokenRefreshTask { return try await tokenRefreshTask.value }
        let task = Task { @MainActor in
            try await self.renewAccessToken()
            guard let token = self.accessToken else { throw SupabaseCloudError.notSignedIn }
            return token
        }
        tokenRefreshTask = task
        defer { tokenRefreshTask = nil }
        return try await task.value
    }

    private static func tokenIsUsable(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = fields["exp"] as? Double else { return false }
        return expiry > Date().timeIntervalSince1970 + 60
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
        try await fetchCloudRecords(
            table: "students",
            select: "id,name,gender,contact_preference,contact_detail,sessions_demand,is_hidden,created_at,updated_at,deleted_at",
            order: "id.asc",
            filters: [URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)")],
            token: token
        )
    }

    private func fetchSessionRecords(token: String) async throws -> [CloudSessionRecord] {
        try await fetchCloudRecords(
            table: "coaching_sessions",
            select: "id,week_start,day_of_week,start_time,end_time,venue,status,court_number,session_fee,session_description,created_at,updated_at,deleted_at",
            order: "id.asc",
            filters: [URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)")],
            token: token
        )
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

    private func insertCloudRecord<Record: Decodable>(
        table: String,
        body: [String: Any],
        token: String
    ) async throws -> Record {
        if let text = body["id"] as? String, let id = UUID(uuidString: text) {
            recordCreationIntent(table: table, id: id)
        }
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
        try await fetchCloudRecords(
            table: "court_bookings",
            select: "id,week_start,day_of_week,start_time,end_time,venue,court_number,created_at,updated_at,deleted_at",
            order: "id.asc",
            filters: [URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)")],
            token: token
        )
    }

    private func fetchSocialSnapshots(token: String) async throws -> [CloudSocialSnapshot] {
        let endpoint = "rpc/coachplanner_social_snapshots"
        let snapshots: [CloudSocialSnapshot]
        do {
            snapshots = try await fetchCloudRecords(
                table: endpoint, select: "id,record,relationships", order: "id.asc",
                filters: [URLQueryItem(name: "p_workspace_id", value: SupabaseConfiguration.workspaceID.uuidString)],
                token: token
            )
        } catch SupabaseCloudError.requestFailed(let message) where message.contains("PGRST202") {
            throw SupabaseCloudError.socialSyncSetupRequired
        }
        guard Set(snapshots.map(\.id)).count == snapshots.count else { throw SupabaseCloudError.invalidResponse }
        for snapshot in snapshots {
            try validateSocialSnapshot(id: snapshot.id, record: snapshot.record, relationships: snapshot.relationships)
        }
        // Publish raw values only after every page is complete and validated.
        // These exact timestamps/rows also protect subsequent writes and review.
        var parents: [[String: Any]] = []
        var children = Dictionary(uniqueKeysWithValues: Self.conflictRelationships(for: "social_sessions").map { ($0.table, [[String: Any]]()) })
        for raw in fetchedConflictRows[endpoint] ?? [] {
            guard let record = raw["record"] as? [String: Any],
                  let relationships = raw["relationships"] as? [String: Any] else { throw SupabaseCloudError.invalidResponse }
            parents.append(record)
            for table in children.keys {
                guard let rows = relationships[table] as? [[String: Any]] else { throw SupabaseCloudError.invalidResponse }
                children[table, default: []].append(contentsOf: rows)
            }
        }
        guard parents.count == snapshots.count else { throw SupabaseCloudError.invalidResponse }
        fetchedConflictRows["social_sessions"] = parents
        for (table, rows) in children { fetchedConflictRows[table] = rows }
        return snapshots
    }

    private func validateSocialSnapshot(id: UUID, record: CloudSocialRecord, relationships: CloudSocialRelationships) throws {
        guard record.id == id,
              relationships.students.allSatisfy({ $0.sessionID == id }),
              relationships.hiddenPeople.allSatisfy({ $0.socialSessionID == id && ($0.studentID != nil) != ($0.outsiderID != nil) }),
              relationships.attendances.allSatisfy({ $0.socialSessionID == id && ($0.studentID != nil) != ($0.outsiderID != nil) }),
              Set(relationships.students.map(\.studentID)).count == relationships.students.count,
              Set(relationships.hiddenPeople.map(\.id)).count == relationships.hiddenPeople.count,
              Set(relationships.attendances.map(\.id)).count == relationships.attendances.count else {
            throw SupabaseCloudError.invalidResponse
        }
    }

    private func writeSocialSnapshot(id: UUID, expected: [String: Any]?, replacement: [String: Any]?,
                                     createdAt: Date?, token: String) async throws -> CloudSocialRecord {
        guard expected != nil || replacement != nil else { throw SupabaseCloudError.invalidResponse }
        let data: Data
        do {
            data = try await send(
                url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/rpc/sync_coachplanner_social"),
                method: "POST",
                body: JSONSerialization.data(withJSONObject: [
                    "p_workspace_id": SupabaseConfiguration.workspaceID.uuidString,
                    "p_record_id": id.uuidString,
                    "p_expected": expected as Any? ?? NSNull(),
                    "p_replacement": replacement as Any? ?? NSNull(),
                    "p_created_at": createdAt.map { Self.isoFormatter.string(from: $0) } ?? NSNull()
                ]), token: token
            )
        } catch SupabaseCloudError.requestFailed(let message) where message.contains("PGRST202") {
            throw SupabaseCloudError.socialSyncSetupRequired
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        let result = try decoder.decode(CloudSocialSnapshotBody.self, from: data)
        try validateSocialSnapshot(id: id, record: result.record, relationships: result.relationships)
        guard (replacement == nil) == (result.record.deletedAt != nil) else { throw SupabaseCloudError.invalidResponse }
        return result.record
    }

    private func fetchOutsiderRecords(token: String) async throws -> [CloudOutsiderRecord] {
        try await fetchCloudRecords(
            table: "outsiders",
            select: "id,name,gender,contact_preference,contact_detail,created_at,updated_at,deleted_at",
            order: "id.asc",
            filters: [URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)")],
            token: token
        )
    }

    private func fetchHiddenWeekRecords(token: String) async throws -> [CloudHiddenWeekRecord] {
        try await fetchCloudRecords(
            table: "student_hidden_weeks",
            select: "student_id,week_start,created_at",
            order: "student_id.asc,week_start.asc",
            token: token
        )
    }

    private func fetchCoachingSessionStudentLinks(token: String) async throws -> [CloudSessionStudentLink] {
        try await fetchCloudRecords(
            table: "coaching_session_students",
            select: "session_id,student_id",
            order: "session_id.asc,student_id.asc",
            token: token
        )
    }

    private func fetchCloudRecords<Record: Decodable>(
        table: String, select: String, order: String,
        filters: [URLQueryItem] = [], token: String,
        applyScope: Bool = true
    ) async throws -> [Record] {
        if applyScope { fetchedConflictRows[table] = [] }
        if applyScope, let (column, ids) = scopedIDs(for: table) {
            // Validate pagination independently for every bounded ID query. A
            // complete scoped result says nothing about records outside it.
            let sortedIDs = ids.map(\.uuidString).sorted()
            var scopedRecords: [Record] = []
            for start in stride(from: 0, to: sortedIDs.count, by: 100) {
                let batch = sortedIDs[start..<min(start + 100, sortedIDs.count)].joined(separator: ",")
                let page: [Record] = try await fetchCloudRecords(
                    table: table, select: select, order: order,
                    filters: filters + [URLQueryItem(name: column, value: "in.(\(batch))")],
                    token: token, applyScope: false
                )
                scopedRecords.append(contentsOf: page)
            }
            return scopedRecords
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        var records: [Record] = []
        var rawRecords: [[String: Any]] = []
        var expectedTotal: Int?
        while true {
            var components = URLComponents(
                url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/\(table)"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = filters + [
                URLQueryItem(name: "select", value: select),
                URLQueryItem(name: "order", value: order),
                URLQueryItem(name: "offset", value: String(records.count)),
                URLQueryItem(name: "limit", value: "500")
            ]
            let (data, response) = try await sendResponse(
                url: components.url!, method: "GET", body: nil, token: token, prefer: "count=exact"
            )
            let page = try decoder.decode([Record].self, from: data)
            // Never reconcile deletions against a server-truncated table.
            guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                  let totalText = range.split(separator: "/").last,
                  let total = Int(totalText), total >= 0,
                  expectedTotal == nil || expectedTotal == total,
                  records.count + page.count <= total else {
                throw SupabaseCloudError.invalidResponse
            }
            expectedTotal = total
            records.append(contentsOf: page)
            guard let rawPage = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw SupabaseCloudError.invalidResponse
            }
            let columns = select.split(separator: ",").map(String.init)
            rawRecords += rawPage.map { row in
                Dictionary(uniqueKeysWithValues: columns.map { ($0, row[$0] ?? NSNull()) })
            }
            if records.count == total {
                fetchedConflictRows[table, default: []].append(contentsOf: rawRecords)
                return records
            }
            guard !page.isEmpty else { throw SupabaseCloudError.invalidResponse }
        }
    }

    private func scopedIDs(for table: String) -> (String, Set<UUID>)? {
        guard let activeScope else { return nil }
        switch table {
        case "students": return ("id", activeScope.students)
        case "outsiders": return ("id", activeScope.outsiders)
        case "court_bookings": return ("id", activeScope.courtBookings)
        case "coaching_sessions": return ("id", activeScope.coachingSessions)
        case "social_sessions", "rpc/coachplanner_social_snapshots": return ("id", activeScope.socialSessions)
        case "student_hidden_weeks": return ("student_id", activeScope.students)
        case "coaching_session_students": return ("session_id", activeScope.coachingSessions)
        case "social_session_students": return ("session_id", activeScope.socialSessions)
        case "social_hidden_people", "social_attendance": return ("social_session_id", activeScope.socialSessions)
        default: return nil
        }
    }

    private func includingUnsyncedDependencies(_ scope: CloudSyncScope, in context: ModelContext) throws -> CloudSyncScope {
        var expanded = scope
        for session in try context.fetch(FetchDescriptor<CoachingSession>())
        where scope.coachingSessions.contains(session.syncID) {
            expanded.students.formUnion(session.studentList.filter { $0.lastSyncedAt == nil }.map(\.syncID))
        }
        for social in try context.fetch(FetchDescriptor<SocialSession>())
        where scope.socialSessions.contains(social.syncID) {
            let students = social.studentList + social.hiddenPersonList.compactMap(\.student) + social.attendanceList.compactMap(\.student)
            let outsiders = social.hiddenPersonList.compactMap(\.outsider) + social.attendanceList.compactMap(\.outsider)
            expanded.students.formUnion(students.filter { $0.lastSyncedAt == nil }.map(\.syncID))
            expanded.outsiders.formUnion(outsiders.filter { $0.lastSyncedAt == nil }.map(\.syncID))
        }
        return expanded
    }

    private func unscopedLedger(_ ledger: [String: Date], ids: Set<UUID>?) -> [String: Date] {
        guard let ids else { return [:] }
        let keys = Set(ids.map(SupabaseSyncLedger.key(for:)))
        return ledger.filter { !keys.contains($0.key) }
    }

    private func deferChange(table: String, id: UUID) {
        deferredChanges.insert(table: table, id: id)
    }

    private func deferLocalEdit<Model: PersistentModel & SyncTimestamped>(_ model: Model, table: String, id: UUID) {
        deferChange(table: table, id: id)
        guard !model.isDeleted, model.modelContext != nil, let baseline = model.lastSyncedAt else { return }
        // Keep an explicit dirty revision even when the device clock is behind
        // the server or an editor has not advanced its save timestamp yet.
        // Otherwise a subsequent remote edit could hide this pending local edit.
        model.updatedAt = max(model.updatedAt, baseline.addingTimeInterval(0.002))
    }

    @discardableResult
    private func acknowledge<Model: PersistentModel & SyncTimestamped>(
        _ model: Model, table: String, id: UUID,
        sent: LocalRevision, current: LocalRevision, serverTimestamp: Date
    ) -> Bool {
        recordAcknowledgement(table: table, id: id, timestamp: serverTimestamp)
        guard !model.isDeleted, model.modelContext != nil else {
            // The upload completed after the user deleted the local record.
            // Retain the acknowledged ledger version so the next pass deletes it.
            deferChange(table: table, id: id)
            return false
        }
        model.lastSyncedAt = serverTimestamp
        guard sent == current else {
            deferLocalEdit(model, table: table, id: id)
            return false
        }
        model.updatedAt = serverTimestamp
        return true
    }

    private func recordAcknowledgement(table: String, id: UUID, timestamp: Date) {
        // A later request may fail after this parent is already on the server.
        // Persist ownership now so deleting it locally cannot reimport it later.
        let key = SupabaseSyncLedger.key(for: id)
        switch table {
        case "students": syncLedger.students[key] = timestamp
        case "outsiders": syncLedger.outsiders[key] = timestamp
        case "court_bookings": syncLedger.courtBookings[key] = timestamp
        case "coaching_sessions": syncLedger.coachingSessions[key] = timestamp
        case "social_sessions": syncLedger.socialSessions[key] = timestamp
        default: return
        }
        syncLedger.save(to: defaults)
    }

    private func recordCreationIntent(table: String, id: UUID) {
        let key = SupabaseSyncLedger.key(for: id)
        let existing: Date?
        switch table {
        case "students": existing = syncLedger.students[key]
        case "outsiders": existing = syncLedger.outsiders[key]
        case "court_bookings": existing = syncLedger.courtBookings[key]
        case "coaching_sessions": existing = syncLedger.coachingSessions[key]
        case "social_sessions": existing = syncLedger.socialSessions[key]
        default: return
        }
        guard existing == nil else { return }
        // A POST may reach the server even if its response is lost. If the user
        // deletes the local row before retrying, this sentinel preserves that
        // intent: an unacknowledged cloud version becomes a visible conflict,
        // never a silently reimported record or an unconditional deletion.
        recordAcknowledgement(table: table, id: id, timestamp: .distantPast)
    }

    private struct LocalRevision: Equatable {
        let updatedAt: Date
        let payload: [String]
    }

    // Compare values as well as timestamps: an editor may have changed a model
    // before SwiftData's save observer advances its timestamp.
    private func revision(of student: Student) -> LocalRevision {
        LocalRevision(updatedAt: student.updatedAt, payload: [
            student.name, student.gender, student.contactPreference, student.contactDetail,
            String(student.sessionsDemand), String(student.isHidden)
        ] + (student.hiddenWeeks ?? []).map { Self.dateOnlyFormatter.string(from: $0.weekStart) }.sorted())
    }

    private func revision(of outsider: Outsider) -> LocalRevision {
        LocalRevision(updatedAt: outsider.updatedAt, payload: [
            outsider.name, outsider.gender, outsider.contactPreference, outsider.contactDetail
        ])
    }

    private func revision(of session: CoachingSession) -> LocalRevision {
        LocalRevision(updatedAt: session.updatedAt, payload: [
            String(describing: session.weekStart), String(session.dayOfWeek),
            String(session.startTime.timeIntervalSince1970), String(session.endTime.timeIntervalSince1970),
            session.venue, session.status, session.courtNumber, String(session.sessionFee),
            String(describing: session.sessionDescription)
        ] + session.studentList.map { $0.syncID.uuidString }.sorted())
    }

    private func revision(of booking: CourtBooking) -> LocalRevision {
        LocalRevision(updatedAt: booking.updatedAt, payload: [
            String(describing: booking.weekStart), String(booking.dayOfWeek),
            String(booking.startTime.timeIntervalSince1970), String(booking.endTime.timeIntervalSince1970),
            booking.venue, booking.courtNumber
        ])
    }

    private func revision(of social: SocialSession) -> LocalRevision {
        let hidden = social.hiddenPersonList.map {
            [$0.syncID.uuidString, $0.student?.syncID.uuidString ?? "", $0.outsider?.syncID.uuidString ?? ""].joined(separator: ":")
        }.sorted()
        let attendance = social.attendanceList.map {
            [$0.syncID.uuidString, $0.student?.syncID.uuidString ?? "", $0.outsider?.syncID.uuidString ?? "",
             $0.status, $0.paymentStatus].joined(separator: ":")
        }.sorted()
        return LocalRevision(updatedAt: social.updatedAt, payload: [
            social.title, String(describing: social.weekStart), String(social.dayOfWeek),
            String(social.startTime.timeIntervalSince1970), String(social.endTime.timeIntervalSince1970),
            social.venue, social.status, String(social.areCourtsBooked), social.courtNumbers,
            String(social.shuttlecockCost), String(social.courtCost)
        ] + social.studentList.map { $0.syncID.uuidString }.sorted() + hidden + attendance)
    }

    private func replaceCloudHiddenWeeks(
        for student: Student,
        rows: [[String: String]],
        token: String
    ) async throws {
        try await deleteCloudRows(
            table: "student_hidden_weeks",
            filters: [URLQueryItem(name: "student_id", value: "eq.\(student.syncID.uuidString)")],
            token: token
        )
        try await insertCloudRows(table: "student_hidden_weeks", rows: rows, token: token)
    }

    private func hiddenWeekRows(for student: Student) -> [[String: String]] {
        (student.hiddenWeeks ?? []).map { hiddenWeek in
            [
                "student_id": student.syncID.uuidString,
                "week_start": Self.dateOnlyFormatter.string(from: hiddenWeek.weekStart),
                "created_at": Self.isoFormatter.string(from: hiddenWeek.createdAt)
            ]
        }
    }

    private func replaceCloudStudents(for session: CoachingSession, rows: [[String: String]], token: String) async throws {
        try await deleteCloudRows(
            table: "coaching_session_students",
            filters: [URLQueryItem(name: "session_id", value: "eq.\(session.syncID.uuidString)")],
            token: token
        )
        try await insertCloudRows(table: "coaching_session_students", rows: rows, token: token)
    }

    private func coachingStudentRows(for session: CoachingSession) -> [[String: String]] {
        session.studentList.map { student in
            [
                "session_id": session.syncID.uuidString,
                "student_id": student.syncID.uuidString
            ]
        }
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

    private struct SocialRelationshipRows {
        let students: [[String: String]]
        let hiddenPeople: [[String: Any]]
        let attendances: [[String: Any]]
    }

    private func socialRelationshipRows(for social: SocialSession) -> SocialRelationshipRows {
        let studentRows = social.studentList.map {
            ["session_id": social.syncID.uuidString, "student_id": $0.syncID.uuidString]
        }
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
            } else { return nil }
            return row
        }
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
            } else { return nil }
            return row
        }
        return SocialRelationshipRows(students: studentRows, hiddenPeople: hiddenRows, attendances: attendanceRows)
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
        let students = try validateSocialDependencies(
            studentIDs: studentIDs, hiddenPeople: hiddenPeople, attendances: attendances,
            studentsByID: studentsByID, outsidersByID: outsidersByID
        )

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

    private func validateSocialDependencies(
        studentIDs: Set<UUID>, hiddenPeople: [CloudHiddenPersonRecord], attendances: [CloudAttendanceRecord],
        studentsByID: [UUID: Student], outsidersByID: [UUID: Outsider]
    ) throws -> [Student] {
        let availableStudents = studentsByID.filter { !$0.value.isDeleted && $0.value.modelContext != nil }
        let availableOutsiders = outsidersByID.filter { !$0.value.isDeleted && $0.value.modelContext != nil }
        let students = studentIDs.compactMap { availableStudents[$0] }
        let requiredStudents = Set(hiddenPeople.compactMap(\.studentID)).union(attendances.compactMap(\.studentID))
        let requiredOutsiders = Set(hiddenPeople.compactMap(\.outsiderID)).union(attendances.compactMap(\.outsiderID))
        guard students.count == studentIDs.count,
              requiredStudents.isSubset(of: Set(availableStudents.keys)),
              requiredOutsiders.isSubset(of: Set(availableOutsiders.keys)),
              hiddenPeople.allSatisfy({ ($0.studentID != nil) != ($0.outsiderID != nil) }),
              attendances.allSatisfy({ ($0.studentID != nil) != ($0.outsiderID != nil) }) else {
            needsDependencyRecovery = activeScope != nil
            throw SupabaseCloudError.invalidResponse
        }

        return students
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

    private func cleanupCloudRelationships(forStudentIDs ids: Set<UUID>, token: String) async throws {
        for table in ["coaching_session_students", "social_session_students", "student_hidden_weeks", "social_hidden_people", "social_attendance"] {
            try await deleteCloudRows(
                table: table, column: "student_id", ids: ids, token: token
            )
        }
    }

    private func cleanupCloudRelationships(forOutsiderIDs ids: Set<UUID>, token: String) async throws {
        for table in ["social_hidden_people", "social_attendance"] {
            try await deleteCloudRows(
                table: table, column: "outsider_id", ids: ids, token: token
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

    private func removeOrphanedSocialChildren(in context: ModelContext, socialIDs: Set<UUID>? = nil) throws {
        SyncTimestamping.isApplyingRemoteChange = true
        defer { SyncTimestamping.isApplyingRemoteChange = false }
        for attendance in try context.fetch(FetchDescriptor<SocialAttendance>())
        where attendance.student == nil && attendance.outsider == nil &&
            (socialIDs == nil || attendance.session.map { socialIDs!.contains($0.syncID) } == true) {
            context.delete(attendance)
        }
        for hiddenPerson in try context.fetch(FetchDescriptor<SocialHiddenPerson>())
        where hiddenPerson.student == nil && hiddenPerson.outsider == nil &&
            (socialIDs == nil || hiddenPerson.session.map { socialIDs!.contains($0.syncID) } == true) {
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

    private func deleteCloudRows(table: String, column: String, ids: Set<UUID>, token: String) async throws {
        // Bound URL length while cleaning old tombstones in batches instead of per record.
        let sortedIDs = ids.map(\.uuidString).sorted()
        for start in stride(from: 0, to: sortedIDs.count, by: 100) {
            let batch = sortedIDs[start..<min(start + 100, sortedIDs.count)].joined(separator: ",")
            try await deleteCloudRows(
                table: table, filters: [URLQueryItem(name: column, value: "in.(\(batch))")], token: token
            )
        }
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
        try await sendResponse(
            url: url, method: method, body: body, authenticated: authenticated, token: token, prefer: prefer
        ).0
    }

    private func sendResponse(
        url: URL,
        method: String,
        body: Data?,
        authenticated: Bool = true,
        token: String? = nil,
        prefer: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try validateSyncAuthentication(authenticated: authenticated)
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

        requestCount += 1
        let (data, response) = try await urlSession.data(for: request)
        try validateSyncAuthentication(authenticated: authenticated)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseCloudError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SupabaseCloudError.requestFailed(message)
        }
        return (data, httpResponse)
    }

    private func validateSyncAuthentication(authenticated: Bool) throws {
        guard isSyncing else { return }
        guard syncingAuthGeneration == authGeneration,
              !authenticated || accessToken != nil else {
            throw SupabaseCloudError.notSignedIn
        }
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

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let ledger = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return ledger
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
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

private struct CloudSocialRelationships: Decodable {
    let students: [CloudSessionStudentLink]
    let hiddenPeople: [CloudHiddenPersonRecord]
    let attendances: [CloudAttendanceRecord]

    enum CodingKeys: String, CodingKey {
        case students = "social_session_students"
        case hiddenPeople = "social_hidden_people"
        case attendances = "social_attendance"
    }
}

private struct CloudSocialSnapshot: Decodable {
    let id: UUID
    let record: CloudSocialRecord
    let relationships: CloudSocialRelationships
}

private struct CloudSocialSnapshotBody: Decodable {
    let record: CloudSocialRecord
    let relationships: CloudSocialRelationships
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
    static var supabaseTimestamp: Self {
        // A decoder reuses its formatters for every date in the response.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let secondsFormatter = ISO8601DateFormatter()
        secondsFormatter.formatOptions = [.withInternetDateTime]
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.calendar = Calendar(identifier: .gregorian)
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        return .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = formatter.date(from: value) { return date }
            if let date = secondsFormatter.date(from: value) { return date }
            if let date = dateOnlyFormatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Supabase timestamp")
        }
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

private extension SupabaseCloud {
    /// Restores only the reviewed person's incoming links. The caller validates
    /// affected parent revisions and rolls back this synchronous apply on error.
    func restoreIncomingConflictRelationships(
        _ relationships: [String: Any], student: Student?, outsider: Outsider?, in context: ModelContext
    ) throws {
        guard (student != nil) != (outsider != nil),
              student?.isDeleted != true, outsider?.isDeleted != true else {
            throw ConflictResolutionError.invalidRelationships
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        func decodeRows<T: Decodable>(_ type: T.Type, key: String) throws -> T {
            guard let rows = relationships[key] as? [[String: Any]] else {
                throw ConflictResolutionError.invalidRelationships
            }
            do { return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: rows)) }
            catch { throw ConflictResolutionError.invalidRelationships }
        }
        let coachingLinks: [CloudSessionStudentLink] = student == nil ? []
            : try decodeRows([CloudSessionStudentLink].self, key: "coaching_session_students")
        let socialLinks: [CloudSessionStudentLink] = student == nil ? []
            : try decodeRows([CloudSessionStudentLink].self, key: "social_session_students")
        let hidden = try decodeRows([CloudHiddenPersonRecord].self, key: "social_hidden_people")
        let attendance = try decodeRows([CloudAttendanceRecord].self, key: "social_attendance")
        guard coachingLinks.allSatisfy({ $0.studentID == student?.syncID }),
              socialLinks.allSatisfy({ $0.studentID == student?.syncID }),
              hidden.allSatisfy({ $0.studentID == student?.syncID && $0.outsiderID == outsider?.syncID }),
              attendance.allSatisfy({ $0.studentID == student?.syncID && $0.outsiderID == outsider?.syncID }),
              Set(coachingLinks.map(\.sessionID)).count == coachingLinks.count,
              Set(socialLinks.map(\.sessionID)).count == socialLinks.count,
              Set(hidden.map(\.id)).count == hidden.count,
              Set(attendance.map(\.id)).count == attendance.count else {
            throw ConflictResolutionError.invalidRelationships
        }
        let coachingByID = Dictionary(grouping: try context.fetch(FetchDescriptor<CoachingSession>()).filter { !$0.isDeleted }, by: \.syncID)
        let socialsByID = Dictionary(grouping: try context.fetch(FetchDescriptor<SocialSession>()).filter { !$0.isDeleted }, by: \.syncID)
        let hiddenByID = Dictionary(grouping: try context.fetch(FetchDescriptor<SocialHiddenPerson>()).filter { !$0.isDeleted }, by: \.syncID)
        let attendanceByID = Dictionary(grouping: try context.fetch(FetchDescriptor<SocialAttendance>()).filter { !$0.isDeleted }, by: \.syncID)
        func coachingParent(_ id: UUID) throws -> CoachingSession {
            guard let matches = coachingByID[id], matches.count == 1 else { throw ConflictResolutionError.invalidRelationships }
            return matches[0]
        }
        func socialParent(_ id: UUID) throws -> SocialSession {
            guard let matches = socialsByID[id], matches.count == 1 else { throw ConflictResolutionError.invalidRelationships }
            return matches[0]
        }
        func matchesExistingPerson(_ existingStudent: Student?, _ existingOutsider: Outsider?) -> Bool {
            (existingStudent == nil || existingStudent?.syncID == student?.syncID) &&
                (existingOutsider == nil || existingOutsider?.syncID == outsider?.syncID)
        }
        // Validate all references before inserting or reconnecting any child.
        for link in coachingLinks {
            let parent = try coachingParent(link.sessionID)
            guard parent.studentList.filter({ $0.syncID == link.studentID }).count <= 1 else {
                throw ConflictResolutionError.invalidRelationships
            }
        }
        for link in socialLinks {
            let parent = try socialParent(link.sessionID)
            guard parent.studentList.filter({ $0.syncID == link.studentID }).count <= 1 else {
                throw ConflictResolutionError.invalidRelationships
            }
        }
        for row in hidden {
            _ = try socialParent(row.socialSessionID)
            let matches = hiddenByID[row.id] ?? []
            guard matches.count <= 1 else { throw ConflictResolutionError.invalidRelationships }
            if let existing = matches.first {
                guard (existing.session == nil || existing.session?.syncID == row.socialSessionID),
                      matchesExistingPerson(existing.student, existing.outsider) else {
                    throw ConflictResolutionError.invalidRelationships
                }
            }
        }
        for row in attendance {
            _ = try socialParent(row.socialSessionID)
            let matches = attendanceByID[row.id] ?? []
            guard matches.count <= 1 else { throw ConflictResolutionError.invalidRelationships }
            if let existing = matches.first {
                guard (existing.session == nil || existing.session?.syncID == row.socialSessionID),
                      matchesExistingPerson(existing.student, existing.outsider) else {
                    throw ConflictResolutionError.invalidRelationships
                }
            }
        }
        if let student {
            for link in coachingLinks {
                let parent = try coachingParent(link.sessionID)
                parent.studentList = parent.studentList.filter { $0.syncID != student.syncID } + [student]
            }
            for link in socialLinks {
                let parent = try socialParent(link.sessionID)
                parent.studentList = parent.studentList.filter { $0.syncID != student.syncID } + [student]
            }
        }
        for row in hidden {
            let parent = try socialParent(row.socialSessionID)
            let child: SocialHiddenPerson
            if let existing = hiddenByID[row.id]?.first { child = existing }
            else if let student {
                child = SocialHiddenPerson(student: student, createdAt: row.createdAt, syncID: row.id)
                context.insert(child)
            } else if let outsider {
                child = SocialHiddenPerson(outsider: outsider, createdAt: row.createdAt, syncID: row.id)
                context.insert(child)
            } else { throw ConflictResolutionError.invalidRelationships }
            child.student = student
            child.outsider = outsider
            child.createdAt = row.createdAt
            // This cloud table has no updated_at column; created_at is the
            // captured child timestamp, not a new local edit time.
            child.updatedAt = row.createdAt
            child.lastSyncedAt = row.createdAt
            child.session = parent
            if !parent.hiddenPersonList.contains(where: { $0.syncID == row.id }) {
                parent.hiddenPersonList.append(child)
            }
        }
        for row in attendance {
            let parent = try socialParent(row.socialSessionID)
            let child: SocialAttendance
            if let existing = attendanceByID[row.id]?.first { child = existing }
            else {
                child = SocialAttendance(student: student, outsider: outsider, createdAt: row.createdAt, syncID: row.id)
                context.insert(child)
            }
            child.student = student
            child.outsider = outsider
            child.status = row.status
            child.paymentStatus = row.paymentStatus
            child.createdAt = row.createdAt
            child.updatedAt = row.updatedAt
            child.lastSyncedAt = row.updatedAt
            child.session = parent
            if !parent.attendanceList.contains(where: { $0.syncID == row.id }) {
                parent.attendanceList.append(child)
            }
        }
    }
}

private enum ConflictResolutionError: LocalizedError {
    case busy, stale, localChanged, unsavedChanges, invalidRelationships, serverSetupRequired

    var errorDescription: String? {
        switch self {
        case .busy: return "Sync is running. Wait for it to finish, then try again."
        case .stale: return "This comparison is out of date. Use Sync cloud data in Settings, then review the updated conflict before choosing again."
        case .localChanged: return "This device changed after the comparison was captured. Your newer edits were kept. Sync cloud data, then review again."
        case .unsavedChanges: return "Finish saving your current edits before resolving a conflict."
        case .invalidRelationships: return "Some related people or attendance entries are unavailable. Sync cloud data before reviewing this conflict again."
        case .serverSetupRequired: return "Conflict resolution needs the latest CoachPlanner database migration. No version was replaced."
        }
    }
}

private enum SupabaseCloudError: LocalizedError {
    case notSignedIn
    case workspaceUnavailable
    case invalidResponse
    case requestFailed(String)
    case conflict
    case socialSyncSetupRequired

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
        case .socialSyncSetupRequired:
            return "Social sync needs the latest CoachPlanner database migration. Your local changes are kept; no partial social upload was attempted."
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
