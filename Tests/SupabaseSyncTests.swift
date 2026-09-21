// Appended to SupabaseCloud.swift by run-supabase-sync-tests.sh.
// Every request is intercepted. Fixtures never use live credentials or app data.
private final class SyncMockServer: @unchecked Sendable {
    let lock = NSLock()
    var tables: [String: [[String: Any]]] = [:]
    var requests: [(method: String, table: String)] = []
    var requestURLs: [URL] = []
    var afterResponse: (@MainActor @Sendable (URLRequest) -> Void)?
    var pageLimit = 500
    var failLaterPage = false
    var failTable: String?
    var failPOSTCountdown: Int?
    var loseNextPOSTResponse = false
    var hiddenReadTables: Set<String> = []
    var rejectNextPatch = false
    var activeRequests = 0
    var peakRequests = 0
    private var tick = 0.0

    func timestamp() -> String {
        tick += 1
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: 1_900_000_000 + tick))
    }

    func rows(_ table: String) -> [[String: Any]] { lock.withLock { tables[table] ?? [] } }
    func clearRequests() { lock.withLock { requests = []; requestURLs = []; peakRequests = 0 } }
    var writes: [(method: String, table: String)] { lock.withLock { requests.filter { $0.method != "GET" } } }

    func edit(_ table: String, id: UUID, fields: [String: Any]) {
        lock.withLock {
            guard let index = tables[table]?.firstIndex(where: { ($0["id"] as? String) == id.uuidString }) else {
                preconditionFailure("Missing fixture")
            }
            tables[table]![index].merge(fields) { _, new in new }
            tables[table]![index]["updated_at"] = timestamp()
        }
    }

    func respond(_ request: URLRequest) throws -> (Int, Data, [String: String]) {
        try lock.withLock {
            let table = request.url!.lastPathComponent
            let method = request.httpMethod!
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            requests.append((method, table))
            requestURLs.append(request.url!)
            if failTable == table { return (503, Data("{}".utf8), [:]) }
            if method == "POST", let countdown = failPOSTCountdown {
                failPOSTCountdown = countdown > 1 ? countdown - 1 : nil
                if countdown == 1 { return (503, Data("{}".utf8), [:]) }
            }
            let offset = Int(query.first { $0.name == "offset" }?.value ?? "0")!
            if failLaterPage && offset > 0 { return (503, Data("{}".utf8), [:]) }
            var rows = tables[table] ?? []
            func matches(_ row: [String: Any]) -> Bool {
                query.allSatisfy { item in
                    guard let value = item.value else { return true }
                    if value.hasPrefix("eq.") {
                        return String(describing: row[item.name] ?? "").lowercased() == String(value.dropFirst(3)).lowercased()
                    }
                    if value == "is.null" { return row[item.name] == nil || row[item.name] is NSNull }
                    if value.hasPrefix("in.(") {
                        let ids = value.dropFirst(4).dropLast().split(separator: ",").map { $0.lowercased() }
                        return ids.contains(String(describing: row[item.name] ?? "").lowercased())
                    }
                    if value.hasPrefix("gte.") { return (row[item.name] as? String ?? "") >= String(value.dropFirst(4)) }
                    if value.hasPrefix("lte.") { return (row[item.name] as? String ?? "") <= String(value.dropFirst(4)) }
                    return true
                }
            }
            var result: [[String: Any]] = []
            var headers: [String: String] = [:]
            switch method {
            case "GET":
                result = hiddenReadTables.contains(table) ? [] : rows.filter(matches)
                if let order = query.first(where: { $0.name == "order" })?.value {
                    let keys = order.split(separator: ",").map { String($0.split(separator: ".")[0]) }
                    result.sort { left, right in
                        for key in keys {
                            let a = String(describing: left[key] ?? ""), b = String(describing: right[key] ?? "")
                            if a != b { return a < b }
                        }
                        return false
                    }
                }
                let total = result.count
                let limit = min(pageLimit, Int(query.first { $0.name == "limit" }?.value ?? "500")!)
                result = Array(result.dropFirst(offset).prefix(limit))
                headers["Content-Range"] = result.isEmpty ? "*/\(total)" : "\(offset)-\(offset + result.count - 1)/\(total)"
            case "POST", "PATCH":
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = try JSONSerialization.jsonObject(with: data)
                if method == "POST" {
                    result = (body as? [[String: Any]]) ?? [body as! [String: Any]]
                    for index in result.indices {
                        result[index]["updated_at"] = timestamp()
                        touchParent(table, row: result[index])
                    }
                    rows.append(contentsOf: result)
                } else if rejectNextPatch {
                    rejectNextPatch = false
                } else {
                    for index in rows.indices where matches(rows[index]) {
                        rows[index].merge(body as! [String: Any]) { _, new in new }
                        rows[index]["updated_at"] = timestamp()
                        result.append(rows[index])
                    }
                }
                tables[table] = rows
            case "DELETE":
                for row in rows where matches(row) { touchParent(table, row: row) }
                rows.removeAll(where: matches)
                tables[table] = rows
            default:
                preconditionFailure("Unexpected request: \(method) \(table)")
            }
            return (200, try JSONSerialization.data(withJSONObject: result), headers)
        }
    }

    private func touchParent(_ table: String, row: [String: Any]) {
        let parent: String, column: String
        switch table {
        case "student_hidden_weeks": parent = "students"; column = "student_id"
        case "coaching_session_students": parent = "coaching_sessions"; column = "session_id"
        case "social_session_students": parent = "social_sessions"; column = "session_id"
        case "social_hidden_people", "social_attendance": parent = "social_sessions"; column = "social_session_id"
        default: return
        }
        guard let id = row[column] as? String,
              let index = tables[parent]?.firstIndex(where: { $0["id"] as? String == id }) else { return }
        tables[parent]![index]["updated_at"] = timestamp()
    }
}

private final class SyncMockProtocol: URLProtocol, @unchecked Sendable {
    static let server = SyncMockServer()
    private var work: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        work = Task {
            Self.server.lock.withLock {
                Self.server.activeRequests += 1
                Self.server.peakRequests = max(Self.server.peakRequests, Self.server.activeRequests)
            }
            defer { Self.server.lock.withLock { Self.server.activeRequests -= 1 } }
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
                let (code, data, headers) = try Self.server.respond(request)
                let loseResponse = Self.server.lock.withLock {
                    guard request.httpMethod == "POST", Self.server.loseNextPOSTResponse else { return false }
                    Self.server.loseNextPOSTResponse = false
                    return true
                }
                if loseResponse { throw URLError(.networkConnectionLost) }
                let afterResponse = Self.server.lock.withLock { Self.server.afterResponse }
                await afterResponse?(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() { work?.cancel() }
}

@main
private struct SupabaseSyncTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        try await SupabaseCloud.runSyncTests()
    }
}

private extension SupabaseCloud {
    static func runSyncTests() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            print("PASS: \(message)")
        }
        func makeContext() throws -> ModelContext {
            let schema = Schema([Student.self, StudentHiddenWeek.self, Outsider.self, CoachingSession.self,
                                 CourtBooking.self, SocialSession.self, SocialHiddenPerson.self, SocialAttendance.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))
            context.autosaveEnabled = false
            return context
        }
        let suite = "CoachPlanner.SyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let receivingDefaults = UserDefaults(suiteName: suite + ".receiver")!
        let cleanerDefaults = UserDefaults(suiteName: suite + ".cleaner")!
        defer {
            defaults.removePersistentDomain(forName: suite)
            receivingDefaults.removePersistentDomain(forName: suite + ".receiver")
            cleanerDefaults.removePersistentDomain(forName: suite + ".cleaner")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let cloud = SupabaseCloud(urlSession: session, defaults: defaults, restoreSession: false)
        cloud.accessToken = "fixture-token"
        let context = try makeContext()
        let server = SyncMockProtocol.server
        let week = dateOnlyFormatter.date(from: "2026-09-14")!
        let start = week.addingTimeInterval(10 * 3600), end = start.addingTimeInterval(3600)
        let student = Student(name: "Test Student", gender: "", contactPreference: .sms, contactDetail: "")
        let outsider = Outsider(name: "Test Outsider", gender: "", contactPreference: .sms, contactDetail: "")
        let coaching = CoachingSession(weekStart: week, dayOfWeek: .monday, startTime: start, endTime: end,
                                       venue: .apex, sessionFee: 50, students: [student])
        let court = CourtBooking(weekStart: week, dayOfWeek: .tuesday, startTime: start, endTime: end,
                                 venue: .apex, courtNumber: "1")
        let attendance = SocialAttendance(student: student, status: .confirmed)
        let hidden = SocialHiddenPerson(outsider: outsider)
        let social = SocialSession(weekStart: week, dayOfWeek: .friday, startTime: start, endTime: end,
                                   venue: .apex, students: [student], hiddenPeople: [hidden], attendances: [attendance])
        context.insert(student); context.insert(outsider); context.insert(coaching); context.insert(court); context.insert(social)
        try context.save()
        await cloud.syncStudentsAndOutsiders(in: context)
        check(cloud.lastError == nil && cloud.lastSyncResult?.pushed == 2, "new people upload without empty relationship requests")
        check(server.writes.count == 2, "two new people need only two writes")
        check(server.peakRequests >= 3, "independent people downloads overlap")
        await cloud.syncCourtsSocialsAndAttendance(in: context)
        await cloud.syncCoachingSessions(in: context)
        check(cloud.lastError == nil, "new coaching, courts and socials upload")
        check(server.rows("social_attendance").count == 1 && server.rows("social_hidden_people").count == 1,
              "new socials preserve attendance and hidden people")
        check(coaching.lastSyncedAt == isoFormatter.date(from: server.rows("coaching_sessions")[0]["updated_at"] as! String),
              "relationship writes use the final parent version")

        server.clearRequests()
        coaching.sessionFee = 75
        coaching.updatedAt = coaching.lastSyncedAt!.addingTimeInterval(10)
        await cloud.syncCoachingSessions(in: context)
        check(cloud.lastError == nil && server.writes.count == 1 && server.writes[0].method == "PATCH",
              "scalar coaching edit needs one write, keeps student links")
        check(server.requests.count == 3, "scalar coaching edit uses 3 total requests instead of 6")
        server.clearRequests()
        student.name = "Edited Student"
        student.updatedAt = student.lastSyncedAt!.addingTimeInterval(10)
        await cloud.syncStudentsAndOutsiders(in: context)
        check(cloud.lastError == nil && server.writes.count == 1, "scalar student edit skips hidden-week replacement")
        server.clearRequests()
        social.title = "Edited Social"
        social.updatedAt = social.lastSyncedAt!.addingTimeInterval(10)
        _ = try await cloud.syncSocialSessions(in: context, token: "fixture-token")
        check(server.writes.count == 1 && server.rows("social_attendance").count == 1,
              "scalar social edit leaves all relationships intact")
        check(server.peakRequests >= 4, "four independent social downloads overlap")

        server.clearRequests()
        attendance.paymentStatus = SocialPaymentStatus.paid.rawValue
        social.updatedAt = social.lastSyncedAt!.addingTimeInterval(10)
        _ = try await cloud.syncSocialSessions(in: context, token: "fixture-token")
        check(server.writes.filter { $0.table == "social_session_students" || $0.table == "social_hidden_people" }.isEmpty,
              "payment edit only replaces attendance")
        check(server.rows("social_attendance")[0]["payment_status"] as? String == "Paid", "payment edit reaches cloud")
        check(social.lastSyncedAt == isoFormatter.date(from: server.rows("social_sessions")[0]["updated_at"] as! String),
              "attendance trigger timestamp is retained")
        server.clearRequests()
        let hiddenWeek = StudentHiddenWeek(student: student, weekStart: week)
        context.insert(hiddenWeek)
        student.updatedAt = student.lastSyncedAt!.addingTimeInterval(10)
        await cloud.syncStudentsAndOutsiders(in: context)
        check(cloud.lastError == nil && server.rows("student_hidden_weeks").count == 1, "week-specific hiding still uploads")
        coaching.studentList = []
        coaching.updatedAt = coaching.lastSyncedAt!.addingTimeInterval(10)
        await cloud.syncCoachingSessions(in: context)
        check(cloud.lastError == nil && server.rows("coaching_session_students").isEmpty, "removing the last student clears links")

        let receiver = SupabaseCloud(urlSession: session, defaults: receivingDefaults, restoreSession: false)
        receiver.accessToken = "fixture-token"
        let receivingContext = try makeContext()
        await receiver.syncStudentsAndOutsiders(in: receivingContext)
        await receiver.syncCourtsSocialsAndAttendance(in: receivingContext)
        await receiver.syncCoachingSessions(in: receivingContext)
        check(receiver.lastError == nil, "fresh device downloads all record types")
        let receivedSocial = try receivingContext.fetch(FetchDescriptor<SocialSession>()).first!
        check(receivedSocial.studentList.count == 1 && receivedSocial.hiddenPersonList.count == 1 &&
              receivedSocial.attendanceList.first?.paymentStatus == "Paid", "fresh device restores social relationships and payment")

        server.clearRequests()
        server.edit("coaching_sessions", id: coaching.syncID, fields: ["session_fee": 90])
        await cloud.syncCoachingSessions(in: context)
        check(cloud.lastError == nil && coaching.sessionFee == 90 && server.writes.isEmpty, "remote edit downloads without uploading")
        server.edit("coaching_sessions", id: coaching.syncID, fields: ["session_fee": 100])
        coaching.sessionFee = 110
        coaching.updatedAt = coaching.lastSyncedAt!.addingTimeInterval(10)
        await cloud.syncCoachingSessions(in: context)
        check(cloud.lastSyncResult?.conflicts == 1 && coaching.sessionFee == 110 && server.writes.isEmpty,
              "divergent edits remain conflicts")
        coaching.updatedAt = coaching.lastSyncedAt!
        await cloud.syncCoachingSessions(in: context)
        server.clearRequests()
        coaching.sessionFee = 120
        coaching.updatedAt = coaching.lastSyncedAt!.addingTimeInterval(10)
        server.rejectNextPatch = true
        let baseline = coaching.lastSyncedAt
        await cloud.syncCoachingSessions(in: context)
        check(cloud.lastError != nil && coaching.lastSyncedAt == baseline && server.writes.count == 1,
              "stale PATCH fails before touching relationships or acknowledging sync")
        coaching.updatedAt = coaching.lastSyncedAt!
        coaching.sessionFee = 100

        context.delete(coaching)
        try context.save()
        await cloud.syncCoachingSessions(in: context)
        check(cloud.lastError == nil && server.rows("coaching_sessions")[0]["deleted_at"] is String,
              "local deletion still creates a cloud tombstone")
        await receiver.syncCoachingSessions(in: receivingContext)
        let receivedSessions = try receivingContext.fetch(FetchDescriptor<CoachingSession>())
        check(receiver.lastError == nil && receivedSessions.isEmpty, "cloud deletion removes the other device's record")
        let tombstone = server.rows("coaching_sessions")[0]
        server.lock.withLock {
            server.tables["coaching_sessions"] = (0..<250).map { _ in
                var row = tombstone; row["id"] = UUID().uuidString; return row
            }
        }
        server.clearRequests()
        await cloud.syncCoachingSessions(in: context)
        check(cloud.lastError == nil && server.writes.isEmpty && server.requests.count == 2,
              "250 clean session tombstones use 2 requests instead of 252")

        var deletedStudent = server.rows("students")[0]
        deletedStudent["deleted_at"] = "2030-01-01T00:00:00.000Z"
        server.lock.withLock {
            server.tables["students"] = (0..<205).map { _ in
                var row = deletedStudent; row["id"] = UUID().uuidString; return row
            }
        }
        let deletionContext = try makeContext()
        let cleaner = SupabaseCloud(urlSession: session, defaults: cleanerDefaults, restoreSession: false)
        cleaner.accessToken = "fixture-token"
        server.clearRequests()
        await cleaner.syncStudentsAndOutsiders(in: deletionContext)
        check(cleaner.lastError == nil && server.writes.filter { $0.method == "DELETE" }.count == 15,
              "205 deleted students batch into 15 cleanup requests instead of 1025")
        server.pageLimit = 37
        server.clearRequests()
        let paged = try await cloud.fetchSessionRecords(token: "fixture-token")
        check(paged.count == 250 && server.requests.count == 7, "pagination respects a lower server row limit")
        server.failLaterPage = true
        server.clearRequests()
        await cloud.syncCoachingSessions(in: context)
        check(cloud.lastError != nil && server.writes.isEmpty, "incomplete download aborts before reconciliation")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabaseTimestamp
        let dates = try decoder.decode([Date].self, from: Data("[\"2026-09-14\",\"2026-09-14T00:00:00Z\",\"2026-09-14T00:00:00.123456+00:00\"]".utf8))
        check(dates.count == 3 && dates[0] == dates[1], "date-only, seconds and fractional timestamps decode")
        try await runIncrementalSyncTests(session: session)
        print("All Supabase sync regression checks passed. No live cloud or app data used.")
    }

    static func runIncrementalSyncTests(session: URLSession) async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            print("PASS: \(message)")
        }
        func makeContext() throws -> ModelContext {
            let schema = Schema([Student.self, StudentHiddenWeek.self, Outsider.self, CoachingSession.self,
                                 CourtBooking.self, SocialSession.self, SocialHiddenPerson.self, SocialAttendance.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            context.autosaveEnabled = false
            return context
        }
        let suite = "CoachPlanner.IncrementalSyncTests.\(UUID().uuidString)"
        let receivingSuite = "CoachPlanner.IncrementalReceiver.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let receivingDefaults = UserDefaults(suiteName: receivingSuite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            receivingDefaults.removePersistentDomain(forName: receivingSuite)
        }
        let server = SyncMockProtocol.server
        server.lock.withLock {
            server.tables = ["workspaces": [["id": SupabaseConfiguration.workspaceID.uuidString]]]
            server.pageLimit = 500
            server.failLaterPage = false
            server.rejectNextPatch = false
        }
        let cloud = SupabaseCloud(urlSession: session, defaults: defaults, restoreSession: false)
        // The payload only contains a far-future expiry. No real credentials or Keychain access.
        cloud.accessToken = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.fixture"
        let receiver = SupabaseCloud(urlSession: session, defaults: receivingDefaults, restoreSession: false)
        receiver.accessToken = cloud.accessToken
        let context = try makeContext()
        let receivingContext = try makeContext()
        let week = dateOnlyFormatter.date(from: "2026-09-14")!
        let start = week.addingTimeInterval(10 * 3600), end = start.addingTimeInterval(3600)
        let first = Student(name: "Scoped Student", gender: "", contactPreference: .sms, contactDetail: "")
        let second = Student(name: "Unscoped Student", gender: "", contactPreference: .sms, contactDetail: "")
        let outsider = Outsider(name: "Scoped Outsider", gender: "", contactPreference: .sms, contactDetail: "")
        let coaching = CoachingSession(weekStart: week, dayOfWeek: .monday, startTime: start, endTime: end,
                                       venue: .apex, sessionFee: 50, students: [first])
        let otherCoaching = CoachingSession(weekStart: week, dayOfWeek: .tuesday, startTime: start, endTime: end,
                                            venue: .apex, sessionFee: 60, students: [second])
        let court = CourtBooking(weekStart: week, dayOfWeek: .tuesday, startTime: start, endTime: end,
                                 venue: .apex, courtNumber: "2")
        let attendance = SocialAttendance(student: first, status: .confirmed)
        let social = SocialSession(weekStart: week, dayOfWeek: .friday, startTime: start, endTime: end,
                                   venue: .apex, students: [first], hiddenPeople: [SocialHiddenPerson(outsider: outsider)],
                                   attendances: [attendance])
        context.insert(first); context.insert(second); context.insert(outsider)
        context.insert(coaching); context.insert(otherCoaching); context.insert(court); context.insert(social)
        try context.save()
        let completeScope = CloudSyncScope(students: [first.syncID, second.syncID], outsiders: [outsider.syncID],
                                          courtBookings: [court.syncID], socialSessions: [social.syncID],
                                          coachingSessions: [coaching.syncID, otherCoaching.syncID])
        server.clearRequests()
        await cloud.syncChanges(completeScope, in: context)
        check(cloud.lastError == nil && cloud.lastSyncResult?.pushed == 7,
              "scoped creation uploads every parent type in dependency order")
        check(server.rows("coaching_session_students").count == 2 && server.rows("social_attendance").count == 1,
              "scoped creation preserves coaching and social relationships")
        server.clearRequests()
        await cloud.syncChanges(CloudSyncScope(), in: context)
        check(server.requests.isEmpty, "empty scope never expands into a full cloud scan")
        await receiver.syncChanges(completeScope, in: receivingContext)
        let initialReceivedCoaching = try receivingContext.fetch(FetchDescriptor<CoachingSession>())
        check(receiver.lastError == nil && initialReceivedCoaching.count == 2,
              "scoped pull restores parent records on another device")

        let otherCoachingID = otherCoaching.syncID
        context.delete(otherCoaching)
        second.name = "Unscoped Pending Edit"
        second.updatedAt = second.lastSyncedAt!.addingTimeInterval(10)
        coaching.sessionFee = 75
        coaching.updatedAt = coaching.lastSyncedAt!.addingTimeInterval(10)
        try context.save()
        server.clearRequests()
        await cloud.syncChanges(CloudSyncScope(coachingSessions: [coaching.syncID]), in: context)
        check(cloud.lastError == nil && cloud.lastSyncResult?.pushed == 1,
              "scoped scalar edit uploads only the changed coaching session")
        check(!(server.rows("coaching_sessions").first { $0["id"] as? String == otherCoachingID.uuidString }?["deleted_at"] is String),
              "missing unscoped local record is not mistaken for a deletion")
        check(server.rows("students").first { $0["id"] as? String == second.syncID.uuidString }?["name"] as? String == "Unscoped Student",
              "unscoped local edit remains pending")
        check(server.requestURLs.filter { $0.lastPathComponent == "coaching_sessions" }.allSatisfy { url in
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains { $0.name == "id" }
        }, "targeted session requests restrict parent IDs")
        await cloud.syncChanges(CloudSyncScope(coachingSessions: [otherCoachingID]), in: context)
        check(cloud.lastError == nil && server.rows("coaching_sessions").first { $0["id"] as? String == otherCoachingID.uuidString }?["deleted_at"] is String,
              "unscoped ledger survives so a later scoped deletion creates a tombstone")
        await receiver.syncChanges(CloudSyncScope(coachingSessions: [otherCoachingID]), in: receivingContext)
        let remainingReceivedCoaching = try receivingContext.fetch(FetchDescriptor<CoachingSession>())
        check(receiver.lastError == nil && remainingReceivedCoaching.count == 1,
              "scoped cloud tombstone removes only the matching local session")

        server.edit("coaching_sessions", id: coaching.syncID, fields: ["session_fee": 90])
        server.clearRequests()
        await cloud.syncChanges(CloudSyncScope(coachingSessions: [coaching.syncID]), in: context)
        check(cloud.lastError == nil && coaching.sessionFee == 90 && server.writes.isEmpty,
              "scoped remote scalar edit downloads without echo writes")
        server.edit("coaching_sessions", id: coaching.syncID, fields: ["session_fee": 100])
        coaching.sessionFee = 110
        coaching.updatedAt = coaching.lastSyncedAt!.addingTimeInterval(10)
        try context.save()
        await cloud.syncChanges(CloudSyncScope(coachingSessions: [coaching.syncID]), in: context)
        check(cloud.lastSyncResult?.conflicts == 1 && coaching.sessionFee == 110 && server.writes.isEmpty,
              "targeted sync retains divergent-edit conflict protection")
        coaching.updatedAt = coaching.lastSyncedAt!
        try context.save()
        await cloud.syncChanges(CloudSyncScope(coachingSessions: [coaching.syncID]), in: context)

        server.edit("court_bookings", id: court.syncID, fields: ["court_number": "3"])
        server.edit("outsiders", id: outsider.syncID, fields: ["name": "Remote Outsider"])
        await cloud.syncChanges(CloudSyncScope(outsiders: [outsider.syncID], courtBookings: [court.syncID]), in: context)
        check(cloud.lastError == nil && court.courtNumber == "3" && outsider.name == "Remote Outsider",
              "targeted court and outsider changes pull correctly")

        let newcomer = Student(name: "New Relationship Student", gender: "", contactPreference: .sms, contactDetail: "")
        let newOutsider = Outsider(name: "New Relationship Outsider", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(newcomer); context.insert(newOutsider)
        coaching.studentList.append(newcomer)
        coaching.updatedAt = coaching.lastSyncedAt!.addingTimeInterval(10)
        social.studentList.append(newcomer)
        social.attendanceList.append(SocialAttendance(student: newcomer, status: .confirmed))
        social.hiddenPersonList.append(SocialHiddenPerson(outsider: newOutsider))
        social.updatedAt = social.lastSyncedAt!.addingTimeInterval(10)
        try context.save()
        await cloud.syncChanges(CloudSyncScope(students: [newcomer.syncID], outsiders: [newOutsider.syncID],
                                              socialSessions: [social.syncID], coachingSessions: [coaching.syncID]), in: context)
        check(cloud.lastError == nil, "targeted upload saves newly referenced people before their relationships")
        await receiver.syncChanges(CloudSyncScope(socialSessions: [social.syncID], coachingSessions: [coaching.syncID]), in: receivingContext)
        let receivedCoaching = try receivingContext.fetch(FetchDescriptor<CoachingSession>()).first!
        let receivedSocial = try receivingContext.fetch(FetchDescriptor<SocialSession>()).first!
        check(receiver.lastError == nil && Set(receivedCoaching.studentList.map(\.syncID)) == [first.syncID, newcomer.syncID],
              "parent-only remote event hydrates missing coaching students")
        check(receivedSocial.attendanceList.contains { $0.student?.syncID == newcomer.syncID } &&
              receivedSocial.hiddenPersonList.contains { $0.outsider?.syncID == newOutsider.syncID },
              "parent-only remote event hydrates missing social attendance and hidden people")

        coaching.studentList = [first]
        coaching.updatedAt = coaching.lastSyncedAt!.addingTimeInterval(10)
        try context.save()
        let laterRelationshipTime = coaching.updatedAt.addingTimeInterval(10)
        server.lock.withLock {
            server.afterResponse = { @MainActor request in
                guard request.httpMethod == "PATCH", request.url?.lastPathComponent == "coaching_sessions" else { return }
                coaching.studentList = [second]
                coaching.updatedAt = laterRelationshipTime
                try! context.save()
            }
        }
        await cloud.syncChanges(CloudSyncScope(coachingSessions: [coaching.syncID]), in: context)
        server.lock.withLock { server.afterResponse = nil }
        let firstRelationshipWrite = Set(server.rows("coaching_session_students")
            .filter { $0["session_id"] as? String == coaching.syncID.uuidString }.compactMap { $0["student_id"] as? String })
        check(cloud.lastError == nil && firstRelationshipWrite == [first.syncID.uuidString] &&
              cloud.deferredChanges.coachingSessions.contains(coaching.syncID),
              "relationship upload uses the frozen first edit while retaining a second saved edit")
        await cloud.syncChanges(CloudSyncScope(coachingSessions: [coaching.syncID]), in: context)
        let secondRelationshipWrite = Set(server.rows("coaching_session_students")
            .filter { $0["session_id"] as? String == coaching.syncID.uuidString }.compactMap { $0["student_id"] as? String })
        check(cloud.lastError == nil && secondRelationshipWrite == [second.syncID.uuidString],
              "next scoped pass uploads the relationship edit made during the previous request")

        first.name = "First Saved Edit"
        first.updatedAt = first.lastSyncedAt!.addingTimeInterval(10)
        try context.save()
        let laterEditTime = first.updatedAt.addingTimeInterval(10)
        server.lock.withLock {
            server.afterResponse = { @MainActor request in
                guard request.httpMethod == "PATCH", request.url?.lastPathComponent == "students" else { return }
                first.name = "Second Saved Edit"
                first.updatedAt = laterEditTime
                try! context.save()
            }
        }
        await cloud.syncChanges(CloudSyncScope(students: [first.syncID]), in: context)
        server.lock.withLock { server.afterResponse = nil }
        check(cloud.lastError == nil && first.name == "Second Saved Edit" && cloud.deferredChanges.students.contains(first.syncID),
              "edit saved during a pending upload remains dirty after its earlier response")
        await cloud.syncChanges(CloudSyncScope(students: [first.syncID]), in: context)
        check(cloud.lastError == nil && server.rows("students").first { $0["id"] as? String == first.syncID.uuidString }?["name"] as? String == "Second Saved Edit",
              "next targeted pass uploads the edit made during the previous request")

        first.name = "Upload Before Skewed Edit"
        first.updatedAt = first.lastSyncedAt!.addingTimeInterval(10)
        try context.save()
        server.lock.withLock {
            server.afterResponse = { @MainActor request in
                guard request.httpMethod == "PATCH", request.url?.lastPathComponent == "students" else { return }
                first.name = "Deferred Edit With Slow Local Clock"
                first.updatedAt = Date(timeIntervalSince1970: 1_600_000_000)
                try! context.save()
            }
        }
        await cloud.syncChanges(CloudSyncScope(students: [first.syncID]), in: context)
        server.lock.withLock { server.afterResponse = nil }
        check(cloud.lastError == nil && first.updatedAt > first.lastSyncedAt!,
              "deferred saved edit remains newer than its acknowledged baseline despite clock skew")
        server.edit("students", id: first.syncID, fields: ["name": "Remote Edit Before Deferred Retry"])
        server.clearRequests()
        await cloud.syncChanges(CloudSyncScope(students: [first.syncID]), in: context)
        check(cloud.lastError == nil && cloud.lastSyncResult?.conflicts == 1 &&
              first.name == "Deferred Edit With Slow Local Clock" && server.writes.isEmpty,
              "remote edit before deferred retry causes conflict instead of overwriting the skewed local edit")
        first.updatedAt = first.lastSyncedAt!
        try context.save()
        await cloud.syncChanges(CloudSyncScope(students: [first.syncID]), in: context)

        server.edit("students", id: first.syncID, fields: ["name": "Competing Remote Edit"])
        let downloadEditTime = first.lastSyncedAt!.addingTimeInterval(30)
        server.lock.withLock {
            server.afterResponse = { @MainActor request in
                guard request.httpMethod == "GET", request.url?.lastPathComponent == "students" else { return }
                first.name = "Saved While Downloading"
                first.updatedAt = downloadEditTime
                try! context.save()
            }
        }
        server.clearRequests()
        await cloud.syncChanges(CloudSyncScope(students: [first.syncID]), in: context)
        server.lock.withLock { server.afterResponse = nil }
        check(cloud.lastError == nil && first.name == "Saved While Downloading" && server.writes.isEmpty,
              "remote download does not overwrite an edit saved while it was in flight")
        await cloud.syncChanges(CloudSyncScope(students: [first.syncID]), in: context)
        check(cloud.lastSyncResult?.conflicts == 1 && first.name == "Saved While Downloading" && server.writes.isEmpty,
              "later pass reports the concurrent saved edit as a conflict")
        first.updatedAt = first.lastSyncedAt!
        try context.save()
        await cloud.syncChanges(CloudSyncScope(students: [first.syncID]), in: context)

        let deletedDuringUpload = Outsider(name: "Deleted During Upload", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(deletedDuringUpload)
        try context.save()
        let deletedDuringUploadID = deletedDuringUpload.syncID
        await cloud.syncChanges(CloudSyncScope(outsiders: [deletedDuringUploadID]), in: context)
        deletedDuringUpload.name = "In-Flight Outsider Edit"
        deletedDuringUpload.updatedAt = deletedDuringUpload.lastSyncedAt!.addingTimeInterval(10)
        try context.save()
        server.lock.withLock {
            server.afterResponse = { @MainActor request in
                guard request.httpMethod == "PATCH", request.url?.lastPathComponent == "outsiders" else { return }
                context.delete(deletedDuringUpload)
                try! context.save()
            }
        }
        await cloud.syncChanges(CloudSyncScope(outsiders: [deletedDuringUploadID]), in: context)
        server.lock.withLock { server.afterResponse = nil }
        let afterInFlightDeletion = try context.fetch(FetchDescriptor<Outsider>())
        check(cloud.lastError == nil && !afterInFlightDeletion.contains { $0.syncID == deletedDuringUploadID } &&
              cloud.deferredChanges.outsiders.contains(deletedDuringUploadID),
              "upload response cannot resurrect a locally deleted record")
        await cloud.syncChanges(CloudSyncScope(outsiders: [deletedDuringUploadID]), in: context)
        check(cloud.lastError == nil && server.rows("outsiders").first { $0["id"] as? String == deletedDuringUploadID.uuidString }?["deleted_at"] is String,
              "next targeted pass tombstones the record deleted during its upload")

        let deletedSocialID = social.syncID
        social.title = "Social Deleted During Upload"
        social.updatedAt = social.lastSyncedAt!.addingTimeInterval(10)
        try context.save()
        server.lock.withLock {
            server.afterResponse = { @MainActor request in
                guard request.httpMethod == "PATCH", request.url?.lastPathComponent == "social_sessions" else { return }
                context.delete(social)
                try! context.save()
            }
        }
        await cloud.syncChanges(CloudSyncScope(socialSessions: [deletedSocialID]), in: context)
        server.lock.withLock { server.afterResponse = nil }
        let remainingSocials = try context.fetch(FetchDescriptor<SocialSession>())
        check(cloud.lastError == nil && remainingSocials.isEmpty && cloud.deferredChanges.socialSessions.contains(deletedSocialID),
              "social deletion during upload safely handles cascade-deleted children")
        await cloud.syncChanges(CloudSyncScope(socialSessions: [deletedSocialID]), in: context)
        check(cloud.lastError == nil && server.rows("social_sessions").first { $0["id"] as? String == deletedSocialID.uuidString }?["deleted_at"] is String,
              "deferred social deletion clears its cloud parent and relationships")

        first.name = "Pending During Failed Download"
        first.updatedAt = first.lastSyncedAt!.addingTimeInterval(10)
        try context.save()
        let beforeFailure = first.lastSyncedAt
        server.lock.withLock { server.pageLimit = 1; server.failLaterPage = true }
        server.clearRequests()
        await cloud.syncChanges(CloudSyncScope(students: [first.syncID, second.syncID, newcomer.syncID]), in: context)
        check(cloud.lastError != nil && server.writes.isEmpty && first.lastSyncedAt == beforeFailure,
              "incomplete targeted pagination fails before writes or sync acknowledgement")
        server.lock.withLock { server.pageLimit = 500; server.failLaterPage = false }

        let stagedStudent = Student(name: "Successful Stage Student", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(stagedStudent)
        try context.save()
        let stagedStudentID = stagedStudent.syncID
        server.lock.withLock { server.failTable = "court_bookings" }
        await cloud.syncChanges(CloudSyncScope(students: [stagedStudentID], courtBookings: [court.syncID]), in: context)
        check(cloud.lastError != nil && stagedStudent.lastSyncedAt != nil,
              "later-stage failure retains an already saved people upload")
        server.lock.withLock { server.failTable = nil }
        context.delete(stagedStudent)
        try context.save()
        let restartedCloud = SupabaseCloud(urlSession: session, defaults: defaults, restoreSession: false)
        restartedCloud.accessToken = cloud.accessToken
        await restartedCloud.syncChanges(CloudSyncScope(students: [stagedStudentID]), in: context)
        check(restartedCloud.lastError == nil && server.rows("students").first { $0["id"] as? String == stagedStudentID.uuidString }?["deleted_at"] is String,
              "successful-stage ledger survives restart after later failure and preserves subsequent deletion")

        let firstPartial = Student(name: "Partial Stage One", gender: "", contactPreference: .sms, contactDetail: "")
        let secondPartial = Student(name: "Partial Stage Two", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(firstPartial); context.insert(secondPartial)
        try context.save()
        let partialIDs: Set<UUID> = [firstPartial.syncID, secondPartial.syncID]
        server.lock.withLock { server.failPOSTCountdown = 2 }
        await restartedCloud.syncChanges(CloudSyncScope(students: partialIDs), in: context)
        let uploadedPartialRows = server.rows("students").filter { row in
            guard let id = row["id"] as? String, let uuid = UUID(uuidString: id) else { return false }
            return partialIDs.contains(uuid)
        }
        check(restartedCloud.lastError != nil && uploadedPartialRows.count == 1,
              "same-stage failed second upload leaves exactly one successful cloud create")
        let uploadedPartialID = UUID(uuidString: uploadedPartialRows[0]["id"] as! String)!
        context.delete(firstPartial.syncID == uploadedPartialID ? firstPartial : secondPartial)
        try context.save()
        let secondRestart = SupabaseCloud(urlSession: session, defaults: defaults, restoreSession: false)
        secondRestart.accessToken = cloud.accessToken
        await secondRestart.syncChanges(CloudSyncScope(students: [uploadedPartialID]), in: context)
        check(secondRestart.lastError == nil && server.rows("students").first { $0["id"] as? String == uploadedPartialID.uuidString }?["deleted_at"] is String,
              "same-stage acknowledged create retains durable deletion baseline after a later request fails")

        let unsentPartialID = partialIDs.first { $0 != uploadedPartialID }!
        await secondRestart.syncChanges(CloudSyncScope(students: [unsentPartialID]), in: context)
        check(secondRestart.lastError == nil && server.rows("students").filter { $0["id"] as? String == unsentPartialID.uuidString }.count == 1,
              "failed create that never reached the server still uploads normally on retry")

        server.lock.withLock {
            server.tables["workspaces"] = []
            server.hiddenReadTables = ["outsiders"]
        }
        server.clearRequests()
        await secondRestart.syncChanges(CloudSyncScope(outsiders: [outsider.syncID]), in: context)
        let outsidersAfterRevocation = try context.fetch(FetchDescriptor<Outsider>())
        check(secondRestart.lastError != nil && outsidersAfterRevocation.contains { $0.syncID == outsider.syncID } && server.writes.isEmpty,
              "revoked workspace access cannot turn RLS-filtered empty results into local deletions")
        server.lock.withLock {
            server.tables["workspaces"] = [["id": SupabaseConfiguration.workspaceID.uuidString]]
            server.hiddenReadTables = []
        }

        let unacknowledged = Student(name: "Lost Create Response", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(unacknowledged)
        try context.save()
        let unacknowledgedID = unacknowledged.syncID
        server.lock.withLock { server.loseNextPOSTResponse = true }
        await secondRestart.syncChanges(CloudSyncScope(students: [unacknowledgedID]), in: context)
        check(secondRestart.lastError != nil && unacknowledged.lastSyncedAt == nil &&
              server.rows("students").filter { $0["id"] as? String == unacknowledgedID.uuidString }.count == 1,
              "lost create response leaves an unacknowledged local upload and one cloud record")
        context.delete(unacknowledged)
        try context.save()
        let uncertainRestart = SupabaseCloud(urlSession: session, defaults: defaults, restoreSession: false)
        uncertainRestart.accessToken = cloud.accessToken
        server.clearRequests()
        await uncertainRestart.syncChanges(CloudSyncScope(students: [unacknowledgedID]), in: context)
        let afterUncertainDeletion = try context.fetch(FetchDescriptor<Student>())
        let uncertainCloudRow = server.rows("students").first { $0["id"] as? String == unacknowledgedID.uuidString }
        check(uncertainRestart.lastError == nil && uncertainRestart.lastSyncResult?.conflicts == 1 &&
              !afterUncertainDeletion.contains { $0.syncID == unacknowledgedID } && server.writes.isEmpty &&
              !(uncertainCloudRow?["deleted_at"] is String),
              "lost response followed by local deletion reports conflict without resurrecting or blindly deleting")

        let keptUnacknowledged = Student(name: "Kept Unacknowledged Create", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(keptUnacknowledged)
        try context.save()
        let keptUnacknowledgedID = keptUnacknowledged.syncID
        server.lock.withLock { server.loseNextPOSTResponse = true }
        await uncertainRestart.syncChanges(CloudSyncScope(students: [keptUnacknowledgedID]), in: context)
        server.edit("students", id: keptUnacknowledgedID, fields: ["name": "Remote Edit After Unacknowledged Create"])
        server.clearRequests()
        await uncertainRestart.syncChanges(CloudSyncScope(students: [keptUnacknowledgedID]), in: context)
        check(uncertainRestart.lastError == nil && uncertainRestart.lastSyncResult?.conflicts == 1 &&
              keptUnacknowledged.name == "Kept Unacknowledged Create" && server.writes.isEmpty &&
              server.rows("students").first { $0["id"] as? String == keptUnacknowledgedID.uuidString }?["name"] as? String == "Remote Edit After Unacknowledged Create",
              "kept unacknowledged create conflicts with a newer cloud edit instead of overwriting either version")
        await uncertainRestart.syncChanges(CloudSyncScope(students: [keptUnacknowledgedID]), in: context)
        check(uncertainRestart.lastError == nil && uncertainRestart.lastSyncResult?.conflicts == 1 &&
              keptUnacknowledged.name == "Kept Unacknowledged Create" && server.writes.isEmpty,
              "repeated retry keeps an unacknowledged-create conflict unresolved without overwriting local data")
    }
}
