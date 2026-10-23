// Appended to the service sources by run-auto-sync-tests.sh. The shared mock
// server intercepts every REST request; no Keychain or installed store is used.
@main
private struct AutoSyncTests {
    @MainActor static func main() async throws {
        try await SupabaseAutoSync.runAutoTests()
    }
}

private extension SupabaseCloud {
    static func automaticSyncFixture(session: URLSession, defaults: UserDefaults) -> SupabaseCloud {
        let cloud = SupabaseCloud(urlSession: session, defaults: defaults, restoreSession: false)
        cloud.setFixtureSignedIn(true)
        return cloud
    }

    func setFixtureSignedIn(_ signedIn: Bool) {
        let payload = Data("{\"exp\":4102444800}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        accessToken = signedIn ? "fixture.\(payload).signature" : nil
        isSignedIn = signedIn
    }

    func setFixtureLastError(_ message: String?) {
        lastError = message
    }
}

private extension SupabaseAutoSync {
    static func runAutoTests() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
            print("PASS: \(message)")
        }
        let firstID = UUID(), secondID = UUID()
        var first = CloudSyncScope(), second = CloudSyncScope()
        first.students.insert(firstID)
        second.coachingSessions.insert(secondID)
        var queue = CloudSyncOutbox()
        queue.enqueue(first)
        check(queue.begin() == first, "A run takes the existing pending scope")
        queue.enqueue(first)
        queue.enqueue(second)
        let durable = try JSONDecoder().decode(CloudSyncScope.self, from: JSONEncoder().encode(queue.durableScope))
        check(durable.students == [firstID] && durable.coachingSessions == [secondID], "Durable state covers in-flight and newly queued changes")
        queue.finish(succeeded: true)
        check(queue.pending.students == [firstID], "Acknowledging one upload preserves another edit of the same ID")
        _ = queue.begin()
        queue.finish(succeeded: false)
        check(queue.pending == durable, "Failed uploads restore every in-flight change")
        let restored = CloudSyncOutbox(pending: durable)
        check(restored.pending == queue.pending && restored.inFlight.isEmpty, "Process restart retries the persisted union")

        let suite = "CoachPlanner.AutoSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: preferenceKey)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncMockProtocol.self]
        let session = URLSession(configuration: config)
        let cloud = SupabaseCloud.automaticSyncFixture(session: session, defaults: defaults)
        SyncMockProtocol.server.lock.withLock {
            SyncMockProtocol.server.tables["workspaces"] = [["id": SupabaseConfiguration.workspaceID.uuidString]]
        }
        let schema = Schema([Student.self, StudentHiddenWeek.self, Outsider.self, CoachingSession.self,
                             CourtBooking.self, SocialSession.self, SocialHiddenPerson.self, SocialAttendance.self, SessionStudentConfirmation.self])
        let modelConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [modelConfig])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let coordinator = SupabaseAutoSync(cloud: cloud, defaults: defaults)
        coordinator.attach(to: context, active: false)
        // Drive ticks explicitly. This avoids wall-clock debounce tests and keeps
        // the real WebSocket disconnected while exercising the real REST path.
        coordinator.timer?.invalidate()
        coordinator.timer = nil
        coordinator.monitor.cancel()
        await Task.yield()
        coordinator.isActive = true
        coordinator.isOnline = true
        coordinator.fullSyncRequested = false
        defer {
            coordinator.isActive = false
            coordinator.stopRealtime()
            coordinator.observations.removeAll()
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            SyncMockProtocol.server.lock.withLock { SyncMockProtocol.server.afterResponse = nil }
        }

        let student = Student(name: "Automatic Fixture", gender: "", contactPreference: .sms, contactDetail: "")
        student.updatedAt = Date(timeIntervalSince1970: 1)
        context.insert(student)
        let beforeSave = Date()
        try context.save()
        check(coordinator.outbox.pending.students.contains(student.syncID), "Real ModelContext didSave queues inserted records")
        check(student.updatedAt >= beforeSave, "Real ModelContext willSave timestamps local changes")
        let persisted = try JSONDecoder().decode(CloudSyncScope.self, from: defaults.data(forKey: coordinator.outboxKey)!)
        check(persisted.students.contains(student.syncID), "A saved edit reaches persistent retry storage")

        let otherContext = ModelContext(container)
        otherContext.autosaveEnabled = false
        let unrelated = Student(name: "Other Context", gender: "", contactPreference: .sms, contactDetail: "")
        otherContext.insert(unrelated)
        try otherContext.save()
        check(!coordinator.outbox.pending.students.contains(unrelated.syncID), "Object-filtered notifications ignore another context")

        // Keep the shared store's unrelated row out of this fixture's full-sync
        // surface; scoped requests should only upload the first saved student.
        try await coordinator.runOneTestPass()
        check(cloud.lastError == nil, "Queued insertion uploads through the real sync service")
        check(SyncMockProtocol.server.rows("students").contains { $0["id"] as? String == student.syncID.uuidString }, "Automatic scope reaches the cloud mock")
        check(!SyncMockProtocol.server.rows("students").contains { $0["id"] as? String == unrelated.syncID.uuidString }, "A scoped upload excludes unrelated records")
        check(coordinator.outbox.pending.students.contains(student.syncID), "Cloud acknowledgement save is queued for a settling pass")
        SyncMockProtocol.server.clearRequests()
        try await coordinator.runOneTestPass()
        check(coordinator.outbox.pending.isEmpty && !context.hasChanges, "A no-op settling pass empties the queue")
        check(SyncMockProtocol.server.writes.isEmpty, "Acknowledgements do not create a write echo loop")

        student.name = "First Saved Edit"
        try context.save()
        check(student.updatedAt > student.lastSyncedAt!,
              "A saved edit advances beyond the mock server's future timestamp despite a lagging device clock")
        let editDuringUpload: @MainActor @Sendable () -> Void = {
            student.name = "Second Edit During Upload"
            try! context.save()
        }
        SyncMockProtocol.server.lock.withLock {
            SyncMockProtocol.server.afterResponse = { request in
                guard request.httpMethod == "PATCH", request.url?.lastPathComponent == "students" else { return }
                SyncMockProtocol.server.lock.withLock { SyncMockProtocol.server.afterResponse = nil }
                editDuringUpload()
            }
        }
        try await coordinator.runOneTestPass()
        check(cloud.lastError == nil && student.name == "Second Edit During Upload", "A save during an upload preserves the newest local value")
        check(coordinator.outbox.pending.students.contains(student.syncID), "The overlapping edit survives upload acknowledgement")
        try await coordinator.runOneTestPass()
        check(SyncMockProtocol.server.rows("students").first { $0["id"] as? String == student.syncID.uuidString }?["name"] as? String == "Second Edit During Upload", "The next queued pass uploads the overlapping edit")
        try await coordinator.runOneTestPass()
        check(coordinator.outbox.pending.isEmpty, "Overlapping edits settle without an infinite loop")

        student.name = "Retry After Failure"
        try context.save()
        SyncMockProtocol.server.lock.withLock { SyncMockProtocol.server.rejectNextPatch = true }
        try await coordinator.runOneTestPass()
        check(cloud.lastError != nil && coordinator.outbox.pending.students.contains(student.syncID), "A rejected upload retains queued edits")
        check(coordinator.retryAfter > Date() && coordinator.retryDelay == 4, "Failed uploads schedule retry with backoff")
        let attemptsAfterFailure = SyncMockProtocol.server.lock.withLock { SyncMockProtocol.server.requests.count }
        coordinator.manualSyncRequested = true
        for _ in 0..<4 { coordinator.tick() }
        check(!coordinator.isRunning && SyncMockProtocol.server.requests.count == attemptsAfterFailure, "Rapid ticks respect retry delay without a request storm")
        try await coordinator.runOneTestPass()
        try await coordinator.runOneTestPass()
        check(coordinator.outbox.pending.isEmpty && cloud.lastError == nil, "A successful retry settles retained changes")

        student.name = "Sign Out During Download"
        try context.save()
        SyncMockProtocol.server.clearRequests()
        SyncMockProtocol.server.lock.withLock {
            SyncMockProtocol.server.afterResponse = { request in
                guard request.httpMethod == "GET", request.url?.lastPathComponent == "students" else { return }
                SyncMockProtocol.server.lock.withLock { SyncMockProtocol.server.afterResponse = nil }
                cloud.setFixtureSignedIn(false)
            }
        }
        try await coordinator.runOneTestPass()
        check(SyncMockProtocol.server.writes.isEmpty, "Signing out during a download prevents subsequent cloud writes")
        check(coordinator.outbox.pending.students.contains(student.syncID), "Sign-out during a request preserves its pending local edit")
        cloud.setFixtureSignedIn(true)
        await Task.yield()
        try await coordinator.runOneTestPass()
        try await coordinator.runOneTestPass()

        student.name = "Saved While Signed Out"
        try context.save()
        cloud.setFixtureSignedIn(false)
        await Task.yield()
        SyncMockProtocol.server.clearRequests()
        coordinator.manualSyncRequested = true
        coordinator.tick()
        check(!coordinator.isRunning && SyncMockProtocol.server.requests.isEmpty, "Signed-out ticks do not issue REST requests")
        cloud.setFixtureSignedIn(true)
        await Task.yield()
        coordinator.networkChanged(false)
        coordinator.tick()
        check(!coordinator.isRunning && SyncMockProtocol.server.requests.isEmpty, "Offline ticks do not issue REST requests")
        coordinator.networkChanged(true)
        try await coordinator.runOneTestPass()
        try await coordinator.runOneTestPass()

        // A save that never reaches didSave must not claim durable success.
        student.name = "Unsaved Fixture"
        NotificationCenter.default.post(name: ModelContext.willSave, object: context)
        check(coordinator.outbox.pending.isEmpty, "willSave alone does not enqueue an unsuccessful save")
        context.rollback()
        coordinator.capturedSave = CloudSyncScope()

        let hidden = StudentHiddenWeek(student: student, weekStart: Date(timeIntervalSince1970: 1_900_000_000))
        context.insert(hidden)
        try context.save()
        check(coordinator.outbox.pending.students.contains(student.syncID), "A relationship-only insert queues its owning student")
        _ = coordinator.outbox.begin()
        coordinator.outbox.finish(succeeded: true)
        context.delete(hidden)
        try context.save()
        check(coordinator.outbox.pending.students.contains(student.syncID), "A relationship-only deletion queues its owning student")

        let start = Date(timeIntervalSince1970: 1_900_000_000), end = start.addingTimeInterval(3600)
        let coaching = CoachingSession(dayOfWeek: .monday, startTime: start, endTime: end, venue: .apex, students: [student])
        let hiddenPerson = SocialHiddenPerson(student: student)
        let attendance = SocialAttendance(student: student)
        let social = SocialSession(weekStart: start, dayOfWeek: .monday, startTime: start, endTime: end, venue: .apex,
                                   students: [student], hiddenPeople: [hiddenPerson], attendances: [attendance])
        context.insert(coaching)
        context.insert(social)
        try context.save()

        _ = coordinator.outbox.begin()
        coordinator.outbox.finish(succeeded: true)
        student.name = "Scalar Edit With Relationships"
        try context.save()
        check(coordinator.outbox.pending.coachingSessions.isEmpty && coordinator.outbox.pending.socialSessions.isEmpty,
              "A normal student edit does not broaden into related sessions")

        _ = coordinator.outbox.begin()
        coordinator.outbox.finish(succeeded: true)
        let studentID = student.syncID
        context.delete(student)
        try context.save()
        check(coordinator.outbox.pending.students.contains(studentID), "Deletion notification retains the deleted record ID")
        check(coordinator.outbox.pending.coachingSessions.contains(coaching.syncID), "Deleting a student queues coaching membership changes")
        check(coordinator.outbox.pending.socialSessions.contains(social.syncID), "Deleting a student queues affected social relationships")

        let outsider = Outsider(name: "Cascade Outsider", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(outsider)
        social.hiddenPersonList.append(SocialHiddenPerson(outsider: outsider))
        social.attendanceList.append(SocialAttendance(student: nil, outsider: outsider))
        try context.save()
        _ = coordinator.outbox.begin()
        coordinator.outbox.finish(succeeded: true)
        context.delete(outsider)
        try context.save()
        check(coordinator.outbox.pending.socialSessions.contains(social.syncID), "Deleting an outsider queues its hidden and attendance session")
        let savedQueue = coordinator.outbox.pending
        let restoredCoordinator = SupabaseAutoSync(cloud: cloud, defaults: defaults)
        check(restoredCoordinator.outbox.pending == savedQueue, "A new coordinator reloads saved deletion and relationship work")
        coordinator.manualSyncRequested = false
        coordinator.fullSyncRequested = false
        SyncMockProtocol.server.clearRequests()
        coordinator.tick()
        check(!coordinator.isRunning && SyncMockProtocol.server.requests.isEmpty, "Automatic opt-out does not start an upload")
        coordinator.connectionRetryDelay = 2
        coordinator.connectionChanged(.disconnected)
        check(coordinator.connectionRetryDelay == 4 && coordinator.nextConnectionAttempt > Date(), "A disconnected channel schedules delayed reconnect")
        for _ in 0..<10 { coordinator.connectionChanged(.disconnected) }
        check(coordinator.connectionRetryDelay == 60, "Reconnect backoff is capped")
        coordinator.connectionChanged(.connected)
        check(coordinator.connectionRetryDelay == 2 && coordinator.fullSyncRequested, "Rejoining resets backoff and schedules missed-change recovery")
        coordinator.fullSyncRequested = false
        coordinator.networkChanged(false)
        check(coordinator.realtimeState == .disconnected, "Network loss closes live transport")
        coordinator.networkChanged(true)
        check(coordinator.fullSyncRequested, "Network restoration schedules recovery")
        coordinator.setActive(false)
        check(coordinator.realtimeState == .disconnected, "Backgrounding disconnects live transport")
        coordinator.manualSyncRequested = true
        coordinator.tick()
        check(!coordinator.isRunning && SyncMockProtocol.server.requests.isEmpty, "Backgrounded app does not start queued requests")

        coordinator.isActive = true
        let conflicted = Student(name: "Conflict Baseline", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(conflicted)
        try context.save()
        try await coordinator.runOneTestPass()
        try await coordinator.runOneTestPass()
        // The mock server uses future timestamps. Give this fixture an older
        // local baseline so the real clock makes its next edit independently new.
        SyncTimestamping.isApplyingRemoteChange = true
        conflicted.lastSyncedAt = Date().addingTimeInterval(-120)
        conflicted.updatedAt = conflicted.lastSyncedAt!
        try context.save()
        SyncTimestamping.isApplyingRemoteChange = false
        conflicted.name = "Locally Edited Conflict"
        try context.save()
        SyncMockProtocol.server.edit("students", id: conflicted.syncID, fields: ["name": "Remote Conflicting Edit"])
        try await coordinator.runOneTestPass()
        check(cloud.lastSyncResult?.conflicts == 1 && coordinator.needsAttention && coordinator.attentionPrompt == .conflict,
              "A real conflict sets persistent coordinator attention")
        check(cloud.conflicts.count == 1 && cloud.conflicts[0].recordID == conflicted.syncID &&
              cloud.conflicts[0].differences.contains { $0.localValue == "Locally Edited Conflict" && $0.cloudValue == "Remote Conflicting Edit" },
              "Coordinator attention is backed by the exact record and values available for review")
        let unrelatedPerson = Outsider(name: "Unrelated Successful Edit", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(unrelatedPerson)
        try context.save()
        try await coordinator.runOneTestPass()
        check(cloud.lastSyncResult?.conflicts == 0 && coordinator.needsAttention && coordinator.attentionPrompt == .conflict,
              "An unrelated scoped success does not hide an existing conflict")
        check(cloud.conflicts.count == 1 && cloud.conflicts[0].recordID == conflicted.syncID,
              "An unrelated successful upload retains the reviewable conflict record")
        SyncMockProtocol.server.edit("students", id: conflicted.syncID, fields: ["name": conflicted.name])
        coordinator.enqueue(CloudSyncScope(students: [conflicted.syncID]))
        try await coordinator.runOneTestPass()
        check(cloud.lastError == nil && cloud.conflicts.isEmpty && !coordinator.needsAttention && coordinator.attentionPrompt == nil,
              "A scoped recheck that resolves the reviewed record immediately clears stale conflict attention")
        try await coordinator.runOneTestPass(full: true)
        check(cloud.lastError == nil && cloud.lastSyncResult?.conflicts == 0 && !coordinator.needsAttention && coordinator.attentionPrompt == nil,
              "A successful full reconciliation clears resolved conflict attention")
        try await Self.runMoveWeekTests { condition, message in
            check(condition, message)
        }
        try await Self.runAttentionPromptTests { condition, message in
            check(condition, message)
        }
        try await Self.runImmediatePushTests { condition, message in
            check(condition, message)
        }
        print("Automatic sync: \(checks) checks passed")
    }

    /// Exercises request construction for reset_coaching_week against the local mock only.
    static func runMoveWeekTests(check: (Bool, String) -> Void) async throws {
        let suite = "CoachPlanner.MoveWeekTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: preferenceKey)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncMockProtocol.self]
        let session = URLSession(configuration: config)
        let cloud = SupabaseCloud.automaticSyncFixture(session: session, defaults: defaults)
        let server = SyncMockProtocol.server
        server.lock.withLock {
            server.tables = ["workspaces": [["id": SupabaseConfiguration.workspaceID.uuidString]]]
            server.failTable = nil
            server.failLaterPage = false
            server.failPOSTCountdown = nil
            server.loseNextPOSTResponse = false
            server.hiddenReadTables = []
            server.rejectNextPatch = false
            server.failResetWeek = false
            server.failSocialChildWrite = false
            server.socialReadOverride = nil
            server.afterResponse = nil
            server.pageLimit = 500
        }
        server.clearRequests()
        let schema = Schema([Student.self, StudentHiddenWeek.self, Outsider.self, CoachingSession.self,
                             CourtBooking.self, SocialSession.self, SocialHiddenPerson.self, SocialAttendance.self, SessionStudentConfirmation.self])
        let modelConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [modelConfig]))
        context.autosaveEnabled = false
        let coordinator = SupabaseAutoSync(cloud: cloud, defaults: defaults)
        coordinator.attach(to: context, active: false)
        coordinator.timer?.invalidate()
        coordinator.timer = nil
        coordinator.monitor.cancel()
        await Task.yield()
        coordinator.isActive = true
        coordinator.isOnline = true
        coordinator.fullSyncRequested = false
        defer {
            coordinator.isActive = false
            coordinator.stopRealtime()
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            server.lock.withLock { server.afterResponse = nil; server.failResetWeek = false }
        }

        var perth = Calendar(identifier: .gregorian)
        perth.timeZone = TimeZone(identifier: "Australia/Perth")!
        perth.locale = Locale(identifier: "en_US_POSIX")
        let week = perth.date(from: DateComponents(year: 2026, month: 10, day: 19))!
        let start = week.addingTimeInterval(10 * 3600)
        let end = start.addingTimeInterval(3600)
        let student = Student(name: "Move Week Student", gender: "", contactPreference: .sms, contactDetail: "")
        let repliedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let coaching = CoachingSession(
            weekStart: week, dayOfWeek: .monday, startTime: start, endTime: end,
            venue: .apex, status: .confirmed, courtNumber: "4", sessionFee: 55, students: [student]
        )
        let court = CourtBooking(weekStart: week, dayOfWeek: .tuesday, startTime: start, endTime: end, venue: .apex, courtNumber: "2")
        let social = SocialSession(weekStart: week, dayOfWeek: .friday, startTime: start, endTime: end, venue: .apex, students: [student])
        context.insert(student)
        context.insert(coaching)
        context.insert(court)
        context.insert(social)
        coaching.setStudentStatus(student, to: .confirmed, respondedAt: repliedAt, in: context)
        try context.save()
        try await coordinator.runOneTestPass(full: true)
        try await coordinator.runOneTestPass(full: true)
        check(cloud.lastError == nil, "Move-week fixture uploads before the reset")
        coaching.sessionFee = 80
        try context.save()
        var tombstone = server.rows("coaching_sessions")[0]
        let tombstoneID = UUID().uuidString
        tombstone["id"] = tombstoneID
        tombstone["deleted_at"] = "2030-01-01T00:00:00.000Z"
        tombstone["court_number"] = "9"
        server.lock.withLock { server.tables["coaching_sessions", default: []].append(tombstone) }

        var weekAtReset: Date?
        var courtAtReset = ""
        var statusAtReset = ""
        var resetMethod: String?
        var resetAuthorization: String?
        var resetAPIKey: String?
        var resetContentType: String?
        server.lock.withLock {
            server.afterResponse = { request in
                guard request.url?.lastPathComponent == "reset_coaching_week" else { return }
                weekAtReset = coaching.weekStart
                courtAtReset = coaching.courtNumber
                statusAtReset = coaching.status
                resetMethod = request.httpMethod
                resetAuthorization = request.value(forHTTPHeaderField: "Authorization")
                resetAPIKey = request.value(forHTTPHeaderField: "apikey")
                resetContentType = request.value(forHTTPHeaderField: "Content-Type")
            }
        }
        server.clearRequests()
        let moved = await coordinator.moveCoachingWeek(from: week, in: context)
        guard case .success(let count) = moved else {
            preconditionFailure("Expected the mock reset to succeed, got \(moved)")
        }
        check(count == 1, "The reset response count includes only the live session")
        check(perth.isDate(weekAtReset!, inSameDayAs: week), "The device has not moved the session when the reset request is sent")
        check(courtAtReset == "4" && statusAtReset == "Confirmed", "Court number and status stay local until the cloud download")
        check(resetMethod == "POST", "Move Sessions posts the reset function")
        check(resetAuthorization?.hasPrefix("Bearer ") == true && resetAPIKey == SupabaseConfiguration.publishableKey,
              "The reset uses the signed-in REST headers")
        check(resetContentType == "application/json", "The reset body is JSON")
        let resetURL = server.requestURLs.first { $0.lastPathComponent == "reset_coaching_week" }
        check(resetURL?.path.hasSuffix("/rest/v1/rpc/reset_coaching_week") == true, "The reset posts to rest/v1/rpc/reset_coaching_week")
        check(server.resetWeekRequests.count == 1 && server.resetWeekRequests[0]["p_from_week"] as? String == "2026-10-19"
              && server.resetWeekRequests[0].count == 1, "The reset body is the viewed week as yyyy-MM-dd")
        let resetAt = server.requests.firstIndex { $0.method == "POST" && $0.table == "reset_coaching_week" }
        check(resetAt != nil && server.requests[..<resetAt!].contains { $0.method != "GET" && $0.table == "coaching_sessions" },
              "Pending local edits upload before the reset")
        check(server.requests[(resetAt! + 1)...].contains { $0.method == "GET" && $0.table == "coaching_sessions" },
              "A successful reset downloads the moved sessions")
        let nextWeek = perth.date(byAdding: .day, value: 7, to: week)!
        check(perth.isDate(coaching.weekStart!, inSameDayAs: nextWeek), "The download places the session on the next week")
        check(coaching.status == "Unscheduled" && coaching.courtNumber == "" && coaching.sessionFee == 80,
              "The download applies Unscheduled, a cleared court, and the uploaded fee")
        check(coaching.confirmationStatus(for: student) == .pending && coaching.respondedAt(for: student) == nil,
              "The download resets the student to Pending with no reply time")
        let movedStart = perth.dateComponents([.hour, .minute], from: coaching.startTime)
        let originalStart = perth.dateComponents([.hour, .minute], from: start)
        check(movedStart.hour == originalStart.hour && movedStart.minute == originalStart.minute,
              "The moved session keeps its local start time")
        check(perth.isDate(court.weekStart!, inSameDayAs: week) && perth.isDate(social.weekStart, inSameDayAs: week),
              "Court bookings and socials stay on the original week")
        let live = server.rows("coaching_sessions").first { ($0["id"] as? String) == coaching.syncID.uuidString }
        let keptTombstone = server.rows("coaching_sessions").first { ($0["id"] as? String) == tombstoneID }
        let liveWeek = live?["week_start"] as? String
        let liveStatus = live?["status"] as? String
        let liveCourt = live?["court_number"] as? String
        let liveFee = (live?["session_fee"] as? NSNumber)?.doubleValue
        check(liveWeek == "2026-10-26" && liveStatus == "Unscheduled" && liveCourt == "",
              "The mock cloud row follows the reset rules")
        check(liveFee == 80, "The uploaded fee is on the cloud row before the reset keeps it")
        let link = server.rows("coaching_session_students").first { ($0["session_id"] as? String)?.lowercased() == coaching.syncID.uuidString.lowercased() }
        let linkStatus = link?["status"] as? String
        let linkReplied = link?["responded_at"]
        check(linkStatus == "Pending" && linkReplied is NSNull, "The cloud student reply is Pending with a null response time")
        let tombstoneWeek = keptTombstone?["week_start"] as? String
        let tombstoneCourt = keptTombstone?["court_number"] as? String
        check(tombstoneWeek == "2026-10-19" && tombstoneCourt == "9",
              "A deleted coaching session is not moved")

        server.clearRequests()
        server.lock.withLock { server.failResetWeek = true; server.afterResponse = nil }
        let failedWeek = coaching.weekStart!
        let failed = await coordinator.moveCoachingWeek(from: failedWeek, in: context)
        guard case .failure(.blocked(let failureMessage)) = failed else {
            preconditionFailure("Expected a failed reset to change nothing, got \(failed)")
        }
        check(failureMessage.hasPrefix("Sessions were not moved."), "A failed reset explains that nothing was moved")
        check(perth.isDate(coaching.weekStart!, inSameDayAs: nextWeek) && coaching.courtNumber == "" && coaching.status == "Unscheduled",
              "A failed reset leaves the downloaded session unchanged")
        check(server.rows("coaching_sessions").first { ($0["id"] as? String) == coaching.syncID.uuidString }?["week_start"] as? String == "2026-10-26",
              "A failed reset does not move the cloud row either")
        let failedResetAt = server.requests.lastIndex { $0.table == "reset_coaching_week" }
        check(failedResetAt == server.requests.count - 1, "A failed reset does not download afterwards")
        check(server.resetWeekRequests.last?["p_from_week"] as? String == "2026-10-26", "The failed request still carries the viewed week")

        coaching.sessionFee = 90
        try context.save()
        server.clearRequests()
        coordinator.networkChanged(false)
        let offline = await coordinator.moveCoachingWeek(from: coaching.weekStart!, in: context)
        guard case .failure(.offline) = offline else {
            preconditionFailure("Expected an offline move to be refused, got \(offline)")
        }
        check(MoveCoachingWeekFailure.offline.alertMessage == "Moving sessions needs an internet connection.",
              "Offline move explains that an internet connection is required")
        check(server.requests.isEmpty && coaching.sessionFee == 90, "An offline move uploads nothing and keeps the local edit")
        check((server.rows("coaching_sessions").first { ($0["id"] as? String) == coaching.syncID.uuidString }?["session_fee"] as? NSNumber)?.doubleValue == 80,
              "An offline move does not change the cloud fee")
        coordinator.networkChanged(true)

        cloud.setFixtureSignedIn(false)
        server.clearRequests()
        let signedOut = await coordinator.moveCoachingWeek(from: coaching.weekStart!, in: context)
        guard case .failure(.signedOut) = signedOut else {
            preconditionFailure("Expected a signed-out move to be refused, got \(signedOut)")
        }
        check(server.requests.isEmpty && coaching.sessionFee == 90,
              "A signed-out move makes no request and keeps the local edit")
    }

    func runOneTestPass(full: Bool = false) async throws {
        manualSyncRequested = true
        fullSyncRequested = full
        retryAfter = .distantPast
        tick()
        for _ in 0..<500 {
            if !isRunning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Mock sync did not finish within five seconds")
    }

    static func runImmediatePushTests(check: (Bool, String) -> Void) async throws {
        let suite = "CoachPlanner.ImmediatePush.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: preferenceKey)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncMockProtocol.self]
        let session = URLSession(configuration: config)
        let cloud = SupabaseCloud.automaticSyncFixture(session: session, defaults: defaults)
        SyncMockProtocol.server.lock.withLock {
            SyncMockProtocol.server.tables["workspaces"] = [["id": SupabaseConfiguration.workspaceID.uuidString]]
            SyncMockProtocol.server.failTable = nil
            SyncMockProtocol.server.loseNextPOSTResponse = false
        }
        let schema = Schema([Student.self, StudentHiddenWeek.self, Outsider.self, CoachingSession.self,
                             CourtBooking.self, SocialSession.self, SocialHiddenPerson.self, SocialAttendance.self, SessionStudentConfirmation.self])
        let modelConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [modelConfig]))
        context.autosaveEnabled = false
        let coordinator = SupabaseAutoSync(cloud: cloud, defaults: defaults)
        coordinator.attach(to: context, active: false)
        coordinator.timer?.invalidate()
        coordinator.timer = nil
        coordinator.monitor.cancel()
        coordinator.isActive = true
        coordinator.isOnline = true
        coordinator.fullSyncRequested = false
        coordinator.manualSyncRequested = false
        defer {
            coordinator.debounceTask?.cancel()
            coordinator.isActive = false
            coordinator.stopRealtime()
            coordinator.observations.removeAll()
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
        }

        func waitUntilIdle() async {
            for _ in 0..<500 where coordinator.isRunning {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(!coordinator.isRunning, "Immediate push did not finish")
        }

        let now = Date()
        let student = Student(name: "Instant Ada", gender: "", contactPreference: .sms, contactDetail: "")
        let outsider = Outsider(name: "Instant Owen", gender: "", contactPreference: .sms, contactDetail: "")
        let coaching = CoachingSession(dayOfWeek: .monday, startTime: now, endTime: now.addingTimeInterval(3600), venue: .apex, students: [student])
        let booking = CourtBooking(dayOfWeek: .tuesday, startTime: now, endTime: now.addingTimeInterval(3600), venue: .apex, courtNumber: "1")
        let hidden = SocialHiddenPerson(student: student)
        let attendance = SocialAttendance(student: student, status: .unscheduled)
        let social = SocialSession(weekStart: now, dayOfWeek: .friday, startTime: now, endTime: now.addingTimeInterval(3600), venue: .trs, students: [student], hiddenPeople: [hidden], attendances: [attendance])
        let confirmation = SessionStudentConfirmation(student: student)
        confirmation.session = coaching
        for model in [student, outsider, coaching, booking, social, hidden, attendance, confirmation] as [any PersistentModel] {
            context.insert(model)
        }
        try context.save()
        let queued = coordinator.outbox.pending
        check(queued.students.contains(student.syncID)
              && queued.outsiders.contains(outsider.syncID)
              && queued.coachingSessions.contains(coaching.syncID)
              && queued.courtBookings.contains(booking.syncID)
              && queued.socialSessions.contains(social.syncID),
              "A local save queues students, outsiders, sessions, bookings, socials, attendance, and hidden people")
        SyncMockProtocol.server.clearRequests()
        coordinator.startUploadIfDue(at: Date(), immediate: false)
        check(!coordinator.isRunning && SyncMockProtocol.server.requests.isEmpty,
              "A push waits about half a second after the last save")
        coordinator.startUploadIfDue(at: coordinator.lastEnqueue.addingTimeInterval(0.6), immediate: false)
        check(coordinator.isRunning, "A push starts once the short debounce has passed")
        await waitUntilIdle()
        let pushedTables = Set(SyncMockProtocol.server.writes.map(\.table))
        check(coordinator.outbox.pending.isEmpty && coordinator.attentionPrompt == nil
              && pushedTables.isSuperset(of: ["students", "outsiders", "coaching_sessions", "court_bookings"])
              && pushedTables.contains { $0 == "social_sessions" || $0 == "sync_coachplanner_social" },
              "The debounced push uploads every queued record and stays quiet")

        context.delete(student)
        try context.save()
        check(coordinator.outbox.pending.students.contains(student.syncID), "Deleting a student queues that student immediately")
        SyncMockProtocol.server.clearRequests()
        coordinator.debounceTask?.cancel()
        coordinator.setActive(false)
        check(coordinator.isRunning, "Leaving the app uploads pending edits without waiting for the debounce")
        await waitUntilIdle()
        check(coordinator.outbox.pending.students.isEmpty && coordinator.attentionPrompt == nil
              && SyncMockProtocol.server.writes.contains { $0.table == "students" },
              "A background flush pushes the deletion and stays quiet")

        coordinator.isActive = true
        coordinator.isOnline = false
        let laterOutsider = Outsider(name: "Offline Uma", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(laterOutsider)
        try context.save()
        SyncMockProtocol.server.clearRequests()
        coordinator.debounceTask?.cancel()
        coordinator.setActive(false)
        check(!coordinator.isRunning && SyncMockProtocol.server.requests.isEmpty
              && coordinator.outbox.pending.outsiders.contains(laterOutsider.syncID),
              "An offline edit stays in the pending queue")
        coordinator.networkChanged(true)
        check(coordinator.isRunning, "Connectivity returning retries the pending queue")
        await waitUntilIdle()
        check(coordinator.outbox.pending.outsiders.isEmpty
              && SyncMockProtocol.server.writes.contains { $0.table == "outsiders" }
              && coordinator.attentionPrompt == nil,
              "The reconnect push uploads the queued outsider without a prompt")

        coordinator.fullSyncRequested = false
        coordinator.isOnline = false
        coordinator.setActive(true)
        check(coordinator.fullSyncRequested && !coordinator.isRunning,
              "Returning to the foreground asks for a remote pull")
    }

    static func runAttentionPromptTests(check: (Bool, String) -> Void) async throws {
        let suite = "CoachPlanner.AttentionPrompt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: preferenceKey)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncMockProtocol.self]
        let session = URLSession(configuration: config)
        let cloud = SupabaseCloud.automaticSyncFixture(session: session, defaults: defaults)
        let coordinator = SupabaseAutoSync(cloud: cloud, defaults: defaults)
        coordinator.isOnline = true
        coordinator.isActive = true
        defer {
            coordinator.isActive = false
            coordinator.stopRealtime()
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
        }

        coordinator.updateStatus()
        check(coordinator.attentionPrompt == nil, "A signed-in idle sync stays quiet")
        coordinator.isOnline = false
        coordinator.updateStatus()
        check(coordinator.attentionPrompt == nil, "A brief offline period stays quiet")
        coordinator.isOnline = true

        cloud.setFixtureLastError("The network connection was lost.")
        coordinator.recordUploadAttempt(succeeded: false)
        coordinator.updateStatus()
        check(coordinator.consecutiveUploadFailures == 0 && coordinator.attentionPrompt == nil,
              "A lost connection does not count as a stuck upload")

        cloud.setFixtureLastError("Supabase request failed: HTTP 500")
        coordinator.recordUploadAttempt(succeeded: false)
        coordinator.recordUploadAttempt(succeeded: false)
        coordinator.updateStatus()
        check(coordinator.consecutiveUploadFailures == 2 && coordinator.attentionPrompt == nil,
              "Two failed uploads stay quiet while retry continues")
        coordinator.recordUploadAttempt(succeeded: false)
        coordinator.updateStatus()
        check(coordinator.attentionPrompt == .uploadFailed && coordinator.attentionPrompt?.title == "Saved changes are not uploading",
              "Repeated upload failures ask Matthew to open Settings")
        coordinator.isOnline = false
        coordinator.updateStatus()
        check(coordinator.attentionPrompt == nil, "Going offline hides the upload prompt until the connection returns")
        coordinator.isOnline = true
        coordinator.recordUploadAttempt(succeeded: true)
        cloud.setFixtureLastError(nil)
        coordinator.updateStatus()
        check(coordinator.consecutiveUploadFailures == 0 && coordinator.attentionPrompt == nil,
              "A successful upload clears the stuck-upload prompt")

        cloud.setFixtureLastError("Sign in to Supabase first.")
        coordinator.updateStatus()
        check(coordinator.attentionPrompt == .signIn, "An expired session asks for sign-in immediately")
        cloud.setFixtureSignedIn(false)
        cloud.setFixtureLastError(nil)
        coordinator.updateStatus()
        check(coordinator.attentionPrompt == .signIn && coordinator.attentionPrompt?.title == "Sign in to keep this device in sync",
              "Signing out asks for sign-in")
        cloud.setFixtureSignedIn(true)
        coordinator.updateStatus()
        check(coordinator.attentionPrompt == nil, "Signing back in removes the prompt")

        coordinator.localSaveError = "Changes could not be saved on this device: disk full"
        coordinator.updateStatus()
        check(coordinator.attentionPrompt == .saveFailed, "A local save failure stays visible")
        coordinator.localSaveError = nil
        coordinator.updateStatus()
        check(coordinator.attentionPrompt == nil, "Clearing the save failure removes the prompt")

        let schema = Schema([Student.self, StudentHiddenWeek.self, Outsider.self, CoachingSession.self,
                             CourtBooking.self, SocialSession.self, SocialHiddenPerson.self, SocialAttendance.self, SessionStudentConfirmation.self])
        let modelConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let addContext = ModelContext(try ModelContainer(for: schema, configurations: [modelConfig]))
        addContext.autosaveEnabled = false
        SyncMockProtocol.server.lock.withLock {
            SyncMockProtocol.server.tables["workspaces"] = [["id": SupabaseConfiguration.workspaceID.uuidString]]
            SyncMockProtocol.server.failTable = nil
            SyncMockProtocol.server.loseNextPOSTResponse = false
        }
        let badVenue = AddSocialSessionParameters(
            date: "2026-10-23", startLocal: "19:00:00", endLocal: "21:00:00", venue: "Nowhere",
            includeEveryone: true, participantIDs: [], title: "Badminton Socials", attendanceStatus: "Unscheduled"
        )
        let refused = await coordinator.addSocialSession(badVenue, in: addContext)
        guard case .failure(.failed(let message)) = refused else {
            preconditionFailure("Expected a venue error, got \(refused)")
        }
        coordinator.updateStatus()
        let addedSocials = try addContext.fetch(FetchDescriptor<SocialSession>())
        check(message.contains("p_venue") && coordinator.attentionPrompt == nil && cloud.lastError == nil && addedSocials.isEmpty,
              "a rejected add tells Matthew on the form and does not raise a sync prompt or save a local copy")
        coordinator.isOnline = false
        let offline = await coordinator.addSocialSession(badVenue, in: addContext)
        guard case .failure(.offline) = offline else {
            preconditionFailure("Expected an offline add to stay local, got \(offline)")
        }
        check(coordinator.attentionPrompt == nil, "offline add does not raise a sync prompt")
        coordinator.isOnline = true
    }
}
