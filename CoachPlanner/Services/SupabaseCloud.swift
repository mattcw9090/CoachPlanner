import Combine
import Foundation
import Security
import SwiftData

enum SupabaseConfiguration {
    static let projectURL = URL(string: "https://bgpjpimhrnmthamzqsgv.supabase.co")!
    static let publishableKey = "sb_publishable_Y6P3ePpdP3hDlwvBuxpSkQ_ec1LNexw"
    static let workspaceID = UUID(uuidString: "0db2b4f5-ff7c-4fbd-b71b-e2ddf9d5def6")!
}

struct CloudSnapshot: Equatable {
    let students: Int
    let outsiders: Int
    let coachingSessions: Int
    let courtBookings: Int
    let socialSessions: Int
    let socialAttendance: Int
    let fetchedAt: Date

    var summary: String {
        "\(students) students, \(coachingSessions) coaching sessions, \(socialSessions) social session"
    }
}

@MainActor
final class SupabaseCloud: ObservableObject {
    static let shared = SupabaseCloud()

    @Published private(set) var isSignedIn = false
    @Published private(set) var snapshot: CloudSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var lastSuccessfulRefreshAt: Date?
    @Published private(set) var lastSyncResult: SyncRunResult?

    private let keychain = SupabaseKeychain()
    private var accessToken: String?

    private let lastRefreshDefaultsKey = "SupabaseCloud.lastSuccessfulRefreshAt"

    private init() {
        accessToken = keychain.read("access_token")
        isSignedIn = accessToken != nil
        lastSuccessfulRefreshAt = UserDefaults.standard.object(forKey: lastRefreshDefaultsKey) as? Date
    }

    func signIn(email: String, password: String) async {
        lastError = nil
        do {
            let session = try await authenticate(email: email, password: password)
            accessToken = session.accessToken
            keychain.write(session.accessToken, key: "access_token")
            if let refreshToken = session.refreshToken {
                keychain.write(refreshToken, key: "refresh_token")
            }
            isSignedIn = true
            let refreshedSnapshot = try await fetchSnapshot()
            snapshot = refreshedSnapshot
            recordSuccessfulRefresh(at: refreshedSnapshot.fetchedAt)
        } catch {
            isSignedIn = false
            lastError = error.localizedDescription
        }
    }

    func refreshSnapshot() async {
        lastError = nil
        do {
            let refreshedSnapshot = try await fetchSnapshotWithTokenRenewal()
            snapshot = refreshedSnapshot
            recordSuccessfulRefresh(at: refreshedSnapshot.fetchedAt)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        accessToken = nil
        snapshot = nil
        isSignedIn = false
        lastSyncResult = nil
        keychain.delete("access_token")
        keychain.delete("refresh_token")
    }

    func syncAll(in context: ModelContext) async {
        var combined = SyncRunResult.zero

        await syncStudentsAndOutsiders(in: context)
        guard lastError == nil, let peopleResult = lastSyncResult else { return }
        combined = combined.adding(peopleResult)

        await syncCourtsSocialsAndAttendance(in: context)
        guard lastError == nil, let socialResult = lastSyncResult else { return }
        combined = combined.adding(socialResult)

        await syncCoachingSessions(in: context)
        guard lastError == nil, let sessionResult = lastSyncResult else { return }
        combined = combined.adding(sessionResult)
        lastSyncResult = combined

        do {
            let refreshedSnapshot = try await fetchSnapshotWithTokenRenewal()
            snapshot = refreshedSnapshot
            recordSuccessfulRefresh(at: refreshedSnapshot.fetchedAt)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func syncCoachingSessions(in context: ModelContext) async {
        lastError = nil
        do {
            guard let accessToken else { throw SupabaseCloudError.notSignedIn }
            let localSessions = try context.fetch(FetchDescriptor<CoachingSession>())
            let cloudSessions = try await fetchSessionRecords(token: accessToken)
            var cloudByID = Dictionary(uniqueKeysWithValues: cloudSessions.map { ($0.id, $0) })
            var pushed = 0
            var pulled = 0
            var conflicts = 0
            var skipped = 0

            for local in localSessions {
                guard let cloud = cloudByID[local.syncID] else {
                    skipped += 1
                    continue
                }
                let baseline = local.lastSyncedAt ?? cloud.updatedAt
                if local.lastSyncedAt == nil {
                    local.lastSyncedAt = baseline
                }
                var localChanged = local.updatedAt > baseline
                let cloudChanged = cloud.updatedAt > baseline
                if !localChanged && !cloudChanged && !cloud.matchesPayload(of: local) {
                    localChanged = true
                }
                if localChanged && cloudChanged {
                    conflicts += 1
                } else if localChanged {
                    let updated = try await updateCloudSession(local, expectedUpdatedAt: baseline, token: accessToken)
                    local.updatedAt = updated.updatedAt
                    local.lastSyncedAt = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
                    SyncTimestamping.isApplyingRemoteChange = true
                    local.weekStart = cloud.weekStart
                    local.dayOfWeek = cloud.dayOfWeek
                    local.startTime = cloud.startTime
                    local.endTime = cloud.endTime
                    local.venue = cloud.venue
                    local.status = cloud.status
                    local.courtNumber = cloud.courtNumber
                    local.sessionFee = cloud.sessionFee
                    local.sessionDescription = cloud.sessionDescription
                    local.updatedAt = cloud.updatedAt
                    local.lastSyncedAt = cloud.updatedAt
                    SyncTimestamping.isApplyingRemoteChange = false
                    pulled += 1
                }
                cloudByID.removeValue(forKey: local.syncID)
            }

            try saveSyncChanges(in: context)
            lastSyncResult = SyncRunResult(
                pushed: pushed,
                pulled: pulled,
                conflicts: conflicts,
                skipped: skipped,
                cloudOnly: cloudByID.count
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
            var pushed = 0
            var pulled = 0
            var conflicts = 0
            var skipped = 0

            for student in localStudents {
                guard let cloud = cloudStudents.first(where: { $0.id == student.syncID }) else {
                    skipped += 1
                    continue
                }
                let baseline = student.lastSyncedAt ?? cloud.updatedAt
                if student.lastSyncedAt == nil {
                    student.lastSyncedAt = baseline
                }
                var localChanged = student.updatedAt > baseline
                let cloudChanged = cloud.updatedAt > baseline
                if !localChanged && !cloudChanged && !cloud.matchesPayload(of: student) {
                    localChanged = true
                }
                if localChanged && cloudChanged { conflicts += 1 }
                else if localChanged {
                    let updated = try await updateCloudStudent(student, expectedUpdatedAt: baseline, token: accessToken)
                    student.updatedAt = updated.updatedAt
                    student.lastSyncedAt = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
                    SyncTimestamping.isApplyingRemoteChange = true
                    student.name = cloud.name; student.gender = cloud.gender
                    student.contactPreference = cloud.contactPreference
                    student.contactDetail = cloud.contactDetail
                    student.sessionsDemand = cloud.sessionsDemand; student.isHidden = cloud.isHidden
                    student.updatedAt = cloud.updatedAt; student.lastSyncedAt = cloud.updatedAt
                    SyncTimestamping.isApplyingRemoteChange = false; pulled += 1
                }
            }

            for outsider in localOutsiders {
                guard let cloud = cloudOutsiders.first(where: { $0.id == outsider.syncID }) else {
                    skipped += 1
                    continue
                }
                let baseline = outsider.lastSyncedAt ?? cloud.updatedAt
                if outsider.lastSyncedAt == nil {
                    outsider.lastSyncedAt = baseline
                }
                var localChanged = outsider.updatedAt > baseline
                let cloudChanged = cloud.updatedAt > baseline
                if !localChanged && !cloudChanged && !cloud.matchesPayload(of: outsider) {
                    localChanged = true
                }
                if localChanged && cloudChanged { conflicts += 1 }
                else if localChanged {
                    let updated = try await updateCloudOutsider(outsider, expectedUpdatedAt: baseline, token: accessToken)
                    outsider.updatedAt = updated.updatedAt
                    outsider.lastSyncedAt = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
                    SyncTimestamping.isApplyingRemoteChange = true
                    outsider.name = cloud.name; outsider.gender = cloud.gender
                    outsider.contactPreference = cloud.contactPreference
                    outsider.contactDetail = cloud.contactDetail
                    outsider.updatedAt = cloud.updatedAt; outsider.lastSyncedAt = cloud.updatedAt
                    SyncTimestamping.isApplyingRemoteChange = false; pulled += 1
                }
            }
            try saveSyncChanges(in: context)
            lastSyncResult = SyncRunResult(
                pushed: pushed,
                pulled: pulled,
                conflicts: conflicts,
                skipped: skipped,
                cloudOnly: 0
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
            let localCourts = try context.fetch(FetchDescriptor<CourtBooking>())
            let localSocials = try context.fetch(FetchDescriptor<SocialSession>())
            let localAttendances = try context.fetch(FetchDescriptor<SocialAttendance>())
            let cloudCourts = try await fetchCourtRecords(token: accessToken)
            let cloudSocials = try await fetchSocialRecords(token: accessToken)
            let cloudAttendances = try await fetchAttendanceRecords(token: accessToken)

            let cloudCourtsByID = Dictionary(uniqueKeysWithValues: cloudCourts.map { ($0.id, $0) })
            let cloudSocialsByID = Dictionary(uniqueKeysWithValues: cloudSocials.map { ($0.id, $0) })
            let cloudAttendancesByID = Dictionary(uniqueKeysWithValues: cloudAttendances.map { ($0.id, $0) })
            var pushed = 0
            var pulled = 0
            var conflicts = 0
            var skipped = 0

            for booking in localCourts {
                guard let cloud = cloudCourtsByID[booking.syncID] else {
                    skipped += 1
                    continue
                }
                let baseline = booking.lastSyncedAt ?? cloud.updatedAt
                if booking.lastSyncedAt == nil {
                    booking.lastSyncedAt = baseline
                }
                var localChanged = booking.updatedAt > baseline
                let cloudChanged = cloud.updatedAt > baseline
                if !localChanged && !cloudChanged && !cloud.matchesPayload(of: booking) {
                    localChanged = true
                }
                if localChanged && cloudChanged {
                    conflicts += 1
                } else if localChanged {
                    let updated = try await updateCloudCourtBooking(
                        booking,
                        expectedUpdatedAt: baseline,
                        token: accessToken
                    )
                    booking.updatedAt = updated.updatedAt
                    booking.lastSyncedAt = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
                    booking.weekStart = cloud.weekStart
                    booking.dayOfWeek = cloud.dayOfWeek
                    booking.startTime = cloud.startTime
                    booking.endTime = cloud.endTime
                    booking.venue = cloud.venue
                    booking.courtNumber = cloud.courtNumber
                    booking.updatedAt = cloud.updatedAt
                    booking.lastSyncedAt = cloud.updatedAt
                    pulled += 1
                }
            }

            for social in localSocials {
                guard let cloud = cloudSocialsByID[social.syncID] else {
                    skipped += 1
                    continue
                }
                let baseline = social.lastSyncedAt ?? cloud.updatedAt
                if social.lastSyncedAt == nil {
                    social.lastSyncedAt = baseline
                }
                var localChanged = social.updatedAt > baseline
                let cloudChanged = cloud.updatedAt > baseline
                if !localChanged && !cloudChanged && !cloud.matchesPayload(of: social) {
                    localChanged = true
                }
                if localChanged && cloudChanged {
                    conflicts += 1
                } else if localChanged {
                    let updated = try await updateCloudSocialSession(
                        social,
                        expectedUpdatedAt: baseline,
                        token: accessToken
                    )
                    social.updatedAt = updated.updatedAt
                    social.lastSyncedAt = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
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
                    pulled += 1
                }
            }

            for attendance in localAttendances {
                guard let cloud = cloudAttendancesByID[attendance.syncID] else {
                    skipped += 1
                    continue
                }
                let baseline = attendance.lastSyncedAt ?? cloud.updatedAt
                if attendance.lastSyncedAt == nil {
                    attendance.lastSyncedAt = baseline
                }
                var localChanged = attendance.updatedAt > baseline
                let cloudChanged = cloud.updatedAt > baseline
                if !localChanged && !cloudChanged && !cloud.matchesPayload(of: attendance) {
                    localChanged = true
                }
                if localChanged && cloudChanged {
                    conflicts += 1
                } else if localChanged {
                    let updated = try await updateCloudAttendance(
                        attendance,
                        expectedUpdatedAt: baseline,
                        token: accessToken
                    )
                    attendance.updatedAt = updated.updatedAt
                    attendance.lastSyncedAt = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
                    attendance.status = cloud.status
                    attendance.paymentStatus = cloud.paymentStatus
                    attendance.updatedAt = cloud.updatedAt
                    attendance.lastSyncedAt = cloud.updatedAt
                    pulled += 1
                }
            }

            try saveSyncChanges(in: context)
            let localCourtIDs = Set(localCourts.map(\.syncID))
            let localSocialIDs = Set(localSocials.map(\.syncID))
            let localAttendanceIDs = Set(localAttendances.map(\.syncID))
            let cloudOnly = cloudCourts.filter { !localCourtIDs.contains($0.id) }.count
                + cloudSocials.filter { !localSocialIDs.contains($0.id) }.count
                + cloudAttendances.filter { !localAttendanceIDs.contains($0.id) }.count
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

    private func recordSuccessfulRefresh(at date: Date) {
        lastSuccessfulRefreshAt = date
        UserDefaults.standard.set(date, forKey: lastRefreshDefaultsKey)
    }

    private func saveSyncChanges(in context: ModelContext) throws {
        guard context.hasChanges else { return }
        SyncTimestamping.isApplyingRemoteChange = true
        defer { SyncTimestamping.isApplyingRemoteChange = false }
        try context.save()
    }

    private func fetchSnapshotWithTokenRenewal() async throws -> CloudSnapshot {
        do {
            return try await fetchSnapshot()
        } catch SupabaseCloudError.requestFailed(let message) where message.contains("JWT expired") {
            try await renewAccessToken()
            return try await fetchSnapshot()
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

    private func fetchSnapshot() async throws -> CloudSnapshot {
        guard let accessToken else {
            throw SupabaseCloudError.notSignedIn
        }

        async let students = fetchIDs(table: "students", token: accessToken)
        async let outsiders = fetchIDs(table: "outsiders", token: accessToken)
        async let coachingSessions = fetchIDs(table: "coaching_sessions", token: accessToken)
        async let courtBookings = fetchIDs(table: "court_bookings", token: accessToken)
        async let socialSessions = fetchIDs(table: "social_sessions", token: accessToken)
        async let socialAttendance = fetchIDs(
            table: "social_attendance",
            token: accessToken,
            scopedToWorkspace: false,
            excludesSoftDeleted: false
        )

        return CloudSnapshot(
            students: try await students.count,
            outsiders: try await outsiders.count,
            coachingSessions: try await coachingSessions.count,
            courtBookings: try await courtBookings.count,
            socialSessions: try await socialSessions.count,
            socialAttendance: try await socialAttendance.count,
            fetchedAt: .now
        )
    }

    private func fetchIDs(
        table: String,
        token: String,
        scopedToWorkspace: Bool = true,
        excludesSoftDeleted: Bool = true
    ) async throws -> [CloudID] {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/").appendingPathComponent(table),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "select", value: "id")]
        if scopedToWorkspace {
            components.queryItems?.append(
                URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)")
            )
        }
        if excludesSoftDeleted {
            components.queryItems?.append(URLQueryItem(name: "deleted_at", value: "is.null"))
        }
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        return try JSONDecoder().decode([CloudID].self, from: data)
    }

    private func fetchStudentRecords(token: String) async throws -> [CloudStudentRecord] {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/students"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,name,gender,contact_preference,contact_detail,sessions_demand,is_hidden,updated_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)"),
            URLQueryItem(name: "deleted_at", value: "is.null")
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
            URLQueryItem(name: "select", value: "id,week_start,day_of_week,start_time,end_time,venue,status,court_number,session_fee,session_description,updated_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)"),
            URLQueryItem(name: "deleted_at", value: "is.null"),
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

    private func updateCloudAttendance(
        _ attendance: SocialAttendance,
        expectedUpdatedAt: Date,
        token: String
    ) async throws -> CloudAttendanceRecord {
        let body: [String: Any] = [
            "status": attendance.status,
            "payment_status": attendance.paymentStatus
        ]
        return try await updateCloudRecord(
            table: "social_attendance",
            id: attendance.syncID,
            body: body,
            expectedUpdatedAt: expectedUpdatedAt,
            token: token
        )
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
            URLQueryItem(name: "select", value: "id,week_start,day_of_week,start_time,end_time,venue,court_number,updated_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)"),
            URLQueryItem(name: "deleted_at", value: "is.null")
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
            URLQueryItem(name: "select", value: "id,title,week_start,day_of_week,start_time,end_time,venue,status,are_courts_booked,court_numbers,shuttlecock_cost,court_cost,updated_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)"),
            URLQueryItem(name: "deleted_at", value: "is.null")
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
            URLQueryItem(name: "select", value: "id,name,gender,contact_preference,contact_detail,updated_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)"),
            URLQueryItem(name: "deleted_at", value: "is.null")
        ]
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        return try decoder.decode([CloudOutsiderRecord].self, from: data)
    }

    private func fetchAttendanceRecords(token: String) async throws -> [CloudAttendanceRecord] {
        let data = try await fetchRelationData(
            table: "social_attendance",
            select: "id,social_session_id,student_id,outsider_id,status,payment_status,updated_at",
            token: token
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        return try decoder.decode([CloudAttendanceRecord].self, from: data)
    }

    private func fetchRelationData(table: String, select: String, token: String) async throws -> Data {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "select", value: select)]
        return try await send(url: components.url!, method: "GET", body: nil, token: token)
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

private struct CloudID: Decodable {
    let id: UUID
}

private struct CloudStudentRecord: Decodable {
    let id: UUID
    let name: String
    let gender: String
    let contactPreference: String
    let contactDetail: String
    let sessionsDemand: Int
    let isHidden: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case gender
        case contactPreference = "contact_preference"
        case contactDetail = "contact_detail"
        case sessionsDemand = "sessions_demand"
        case isHidden = "is_hidden"
        case updatedAt = "updated_at"
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
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, gender
        case contactPreference = "contact_preference"
        case contactDetail = "contact_detail"
        case updatedAt = "updated_at"
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
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case socialSessionID = "social_session_id"
        case studentID = "student_id"
        case outsiderID = "outsider_id"
        case status
        case paymentStatus = "payment_status"
        case updatedAt = "updated_at"
    }

    func matchesPayload(of attendance: SocialAttendance) -> Bool {
        status == attendance.status && paymentStatus == attendance.paymentStatus
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
    let updatedAt: Date

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
        case updatedAt = "updated_at"
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
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case weekStart = "week_start"
        case dayOfWeek = "day_of_week"
        case startTime = "start_time"
        case endTime = "end_time"
        case venue
        case courtNumber = "court_number"
        case updatedAt = "updated_at"
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
    let updatedAt: Date

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
        case updatedAt = "updated_at"
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
    case invalidResponse
    case requestFailed(String)
    case conflict

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Supabase first."
        case .invalidResponse:
            return "Supabase returned an invalid response."
        case .requestFailed(let message):
            return "Supabase request failed: \(message)"
        case .conflict:
            return "The cloud session changed before the local update could be applied."
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
