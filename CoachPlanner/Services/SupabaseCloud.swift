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
    @Published private(set) var lastIdentityLinkResult: IdentityLinkResult?
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
        keychain.delete("access_token")
        keychain.delete("refresh_token")
    }

    func linkExistingIdentityIDs(in context: ModelContext) async {
        lastError = nil
        do {
            guard let accessToken else { throw SupabaseCloudError.notSignedIn }

            let localStudents = try context.fetch(FetchDescriptor<Student>())
            let localOutsiders = try context.fetch(FetchDescriptor<Outsider>())
            let localSessions = try context.fetch(FetchDescriptor<CoachingSession>())
            let localCourts = try context.fetch(FetchDescriptor<CourtBooking>())
            let localSocials = try context.fetch(FetchDescriptor<SocialSession>())
            let localHiddenPeople = try context.fetch(FetchDescriptor<SocialHiddenPerson>())
            let localAttendances = try context.fetch(FetchDescriptor<SocialAttendance>())
            let cloudStudents = try await fetchStudentRecords(token: accessToken)
            let cloudOutsiders = try await fetchOutsiderRecords(token: accessToken)
            let cloudSessions = try await fetchSessionRecords(token: accessToken)
            let cloudCourts = try await fetchCourtRecords(token: accessToken)
            let cloudSocials = try await fetchSocialRecords(token: accessToken)
            let cloudHiddenPeople = try await fetchHiddenPersonRecords(token: accessToken)
            let cloudAttendances = try await fetchAttendanceRecords(token: accessToken)

            var linkedStudents = 0
            let studentsByName = Dictionary(grouping: cloudStudents, by: { $0.name.normalizedSyncName })
            for student in localStudents {
                let candidates = studentsByName[student.name.normalizedSyncName] ?? []
                guard candidates.count == 1, student.syncID != candidates[0].id else { continue }
                student.syncID = candidates[0].id
                student.lastSyncedAt = candidates[0].updatedAt
                linkedStudents += 1
            }

            var linkedOutsiders = 0
            let outsidersByName = Dictionary(grouping: cloudOutsiders, by: { $0.name.normalizedSyncName })
            for outsider in localOutsiders {
                let candidates = outsidersByName[outsider.name.normalizedSyncName] ?? []
                guard candidates.count == 1, outsider.syncID != candidates[0].id else { continue }
                outsider.syncID = candidates[0].id
                linkedOutsiders += 1
            }

            var remainingCloudSessions = cloudSessions
            var linkedSessions = 0
            for session in localSessions {
                guard let index = remainingCloudSessions.firstIndex(where: { $0.matches(session) }) else { continue }
                let cloudSession = remainingCloudSessions.remove(at: index)
                session.syncID = cloudSession.id
                session.lastSyncedAt = cloudSession.updatedAt
                linkedSessions += 1
            }

            var remainingCloudCourts = cloudCourts
            var linkedCourts = 0
            for booking in localCourts {
                guard let index = remainingCloudCourts.firstIndex(where: { $0.matches(booking) }) else { continue }
                booking.syncID = remainingCloudCourts.remove(at: index).id
                linkedCourts += 1
            }

            var remainingCloudSocials = cloudSocials
            var linkedSocials = 0
            for social in localSocials {
                guard let index = remainingCloudSocials.firstIndex(where: { $0.matches(social) }) else { continue }
                social.syncID = remainingCloudSocials.remove(at: index).id
                linkedSocials += 1
            }

            var linkedHiddenPeople = 0
            for hiddenPerson in localHiddenPeople {
                guard let sessionID = hiddenPerson.session?.syncID else { continue }
                let studentID = hiddenPerson.student?.syncID
                let outsiderID = hiddenPerson.outsider?.syncID
                guard let cloudRecord = cloudHiddenPeople.first(where: {
                    $0.socialSessionID == sessionID && $0.studentID == studentID && $0.outsiderID == outsiderID
                }) else { continue }
                hiddenPerson.syncID = cloudRecord.id
                linkedHiddenPeople += 1
            }

            var linkedAttendances = 0
            for attendance in localAttendances {
                guard let sessionID = attendance.session?.syncID else { continue }
                let studentID = attendance.student?.syncID
                let outsiderID = attendance.outsider?.syncID
                guard let cloudRecord = cloudAttendances.first(where: {
                    $0.socialSessionID == sessionID && $0.studentID == studentID &&
                        $0.outsiderID == outsiderID && $0.status == attendance.status &&
                        $0.paymentStatus == attendance.paymentStatus
                }) else { continue }
                attendance.syncID = cloudRecord.id
                linkedAttendances += 1
            }

            if context.hasChanges {
                try context.save()
            }
            lastIdentityLinkResult = IdentityLinkResult(
                studentsLinked: linkedStudents,
                sessionsLinked: linkedSessions,
                sessionsUnmatched: remainingCloudSessions.count,
                courtsLinked: linkedCourts,
                socialsLinked: linkedSocials,
                outsidersLinked: linkedOutsiders,
                hiddenPeopleLinked: linkedHiddenPeople,
                attendancesLinked: linkedAttendances
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func syncCoachingSessions(in context: ModelContext) async {
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
                guard let cloud = cloudByID[local.syncID], let baseline = local.lastSyncedAt else {
                    skipped += 1
                    continue
                }
                let localChanged = local.updatedAt > baseline
                let cloudChanged = cloud.updatedAt > baseline
                if localChanged && cloudChanged {
                    conflicts += 1
                } else if localChanged {
                    let updated = try await updateCloudSession(local, expectedUpdatedAt: baseline, token: accessToken)
                    local.lastSyncedAt = updated.updatedAt
                    pushed += 1
                } else if cloudChanged {
                    SyncTimestamping.isApplyingRemoteChange = true
                    local.startTime = cloud.startTime
                    local.endTime = cloud.endTime
                    local.venue = cloud.venue
                    local.status = cloud.status
                    local.courtNumber = cloud.courtNumber
                    local.updatedAt = cloud.updatedAt
                    local.lastSyncedAt = cloud.updatedAt
                    SyncTimestamping.isApplyingRemoteChange = false
                    pulled += 1
                }
                cloudByID.removeValue(forKey: local.syncID)
            }

            if context.hasChanges { try context.save() }
            lastSyncResult = SyncRunResult(pushed: pushed, pulled: pulled, conflicts: conflicts, skipped: skipped)
        } catch {
            SyncTimestamping.isApplyingRemoteChange = false
            lastError = error.localizedDescription
        }
    }

    private func recordSuccessfulRefresh(at date: Date) {
        lastSuccessfulRefreshAt = date
        UserDefaults.standard.set(date, forKey: lastRefreshDefaultsKey)
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
        async let socialAttendance = fetchIDs(table: "social_attendance", token: accessToken, scopedToWorkspace: false)

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

    private func fetchIDs(table: String, token: String, scopedToWorkspace: Bool = true) async throws -> [CloudID] {
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
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        return try JSONDecoder().decode([CloudID].self, from: data)
    }

    private func fetchStudentRecords(token: String) async throws -> [CloudStudentRecord] {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/students"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,name,updated_at"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)"),
            URLQueryItem(name: "deleted_at", value: "is.null")
        ]
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        return try JSONDecoder().decode([CloudStudentRecord].self, from: data)
    }

    private func fetchSessionRecords(token: String) async throws -> [CloudSessionRecord] {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/coaching_sessions"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,start_time,end_time,venue,status,court_number,updated_at"),
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
            URLQueryItem(name: "updated_at", value: "eq.\(Self.isoFormatter.string(from: expectedUpdatedAt))")
        ]
        let body: [String: Any] = [
            "start_time": Self.isoFormatter.string(from: session.startTime),
            "end_time": Self.isoFormatter.string(from: session.endTime),
            "venue": session.venue,
            "status": session.status,
            "court_number": session.courtNumber
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

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func fetchCourtRecords(token: String) async throws -> [CloudCourtRecord] {
        var components = URLComponents(
            url: SupabaseConfiguration.projectURL.appendingPathComponent("rest/v1/court_bookings"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,start_time,end_time,venue,court_number"),
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
            URLQueryItem(name: "select", value: "id,title,start_time,end_time,venue,status,court_numbers"),
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
            URLQueryItem(name: "select", value: "id,name"),
            URLQueryItem(name: "workspace_id", value: "eq.\(SupabaseConfiguration.workspaceID.uuidString)"),
            URLQueryItem(name: "deleted_at", value: "is.null")
        ]
        let data = try await send(url: components.url!, method: "GET", body: nil, token: token)
        return try JSONDecoder().decode([CloudOutsiderRecord].self, from: data)
    }

    private func fetchHiddenPersonRecords(token: String) async throws -> [CloudHiddenPersonRecord] {
        let data = try await fetchRelationData(table: "social_hidden_people", select: "id,social_session_id,student_id,outsider_id", token: token)
        return try JSONDecoder().decode([CloudHiddenPersonRecord].self, from: data)
    }

    private func fetchAttendanceRecords(token: String) async throws -> [CloudAttendanceRecord] {
        let data = try await fetchRelationData(table: "social_attendance", select: "id,social_session_id,student_id,outsider_id,status,payment_status", token: token)
        return try JSONDecoder().decode([CloudAttendanceRecord].self, from: data)
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

struct IdentityLinkResult: Equatable {
    let studentsLinked: Int
    let sessionsLinked: Int
    let sessionsUnmatched: Int
    let courtsLinked: Int
    let socialsLinked: Int
    let outsidersLinked: Int
    let hiddenPeopleLinked: Int
    let attendancesLinked: Int
}

struct SyncRunResult: Equatable {
    let pushed: Int
    let pulled: Int
    let conflicts: Int
    let skipped: Int
}

private struct CloudID: Decodable {
    let id: UUID
}

private struct CloudStudentRecord: Decodable {
    let id: UUID
    let name: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case updatedAt = "updated_at"
    }
}

private struct CloudOutsiderRecord: Decodable {
    let id: UUID
    let name: String
}

private struct CloudHiddenPersonRecord: Decodable {
    let id: UUID
    let socialSessionID: UUID
    let studentID: UUID?
    let outsiderID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case socialSessionID = "social_session_id"
        case studentID = "student_id"
        case outsiderID = "outsider_id"
    }
}

private struct CloudAttendanceRecord: Decodable {
    let id: UUID
    let socialSessionID: UUID
    let studentID: UUID?
    let outsiderID: UUID?
    let status: String
    let paymentStatus: String

    enum CodingKeys: String, CodingKey {
        case id
        case socialSessionID = "social_session_id"
        case studentID = "student_id"
        case outsiderID = "outsider_id"
        case status
        case paymentStatus = "payment_status"
    }
}

private struct CloudSessionRecord: Decodable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let venue: String
    let status: String
    let courtNumber: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case endTime = "end_time"
        case venue
        case status
        case courtNumber = "court_number"
        case updatedAt = "updated_at"
    }

    func matches(_ session: CoachingSession) -> Bool {
        abs(startTime.timeIntervalSince(session.startTime)) < 1 &&
            abs(endTime.timeIntervalSince(session.endTime)) < 1 &&
            venue == session.venue &&
            status == session.status &&
            courtNumber == session.courtNumber
    }
}

private struct CloudCourtRecord: Decodable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let venue: String
    let courtNumber: String

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case endTime = "end_time"
        case venue
        case courtNumber = "court_number"
    }

    func matches(_ booking: CourtBooking) -> Bool {
        abs(startTime.timeIntervalSince(booking.startTime)) < 1 &&
            abs(endTime.timeIntervalSince(booking.endTime)) < 1 &&
            venue == booking.venue &&
            courtNumber == booking.courtNumber
    }
}

private struct CloudSocialRecord: Decodable {
    let id: UUID
    let title: String
    let startTime: Date
    let endTime: Date
    let venue: String
    let status: String
    let courtNumbers: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case startTime = "start_time"
        case endTime = "end_time"
        case venue
        case status
        case courtNumbers = "court_numbers"
    }

    func matches(_ social: SocialSession) -> Bool {
        title == social.title &&
            abs(startTime.timeIntervalSince(social.startTime)) < 1 &&
            abs(endTime.timeIntervalSince(social.endTime)) < 1 &&
            venue == social.venue &&
            status == social.status &&
            courtNumbers == social.courtNumbers
    }
}

private extension String {
    var normalizedSyncName: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}


private extension JSONDecoder.DateDecodingStrategy {
    static let supabaseTimestamp: Self = .custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
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
