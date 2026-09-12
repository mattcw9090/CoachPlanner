// Appended to SupabaseCloud.swift by run-supabase-sync-tests.sh.
// Every request is intercepted. Fixtures never use live credentials or app data.
private final class SyncMockServer: @unchecked Sendable {
    let lock = NSLock()
    var tables: [String: [[String: Any]]] = [:]
    var requests: [(method: String, table: String)] = []
    var pageLimit = 500
    var failLaterPage = false
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
    func clearRequests() { lock.withLock { requests = []; peakRequests = 0 } }
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
                result = rows.filter(matches)
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
        defer { defaults.removePersistentDomain(forName: suite) }
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

        let receiver = SupabaseCloud(urlSession: session, defaults: defaults, restoreSession: false)
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
        let cleaner = SupabaseCloud(urlSession: session, defaults: defaults, restoreSession: false)
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
        print("All Supabase sync regression checks passed. No live cloud or app data used.")
    }
}
