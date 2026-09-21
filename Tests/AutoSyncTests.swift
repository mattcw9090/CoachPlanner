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
                             CourtBooking.self, SocialSession.self, SocialHiddenPerson.self, SocialAttendance.self])
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
        check(cloud.lastSyncResult?.conflicts == 1 && coordinator.needsAttention, "A real conflict sets persistent coordinator attention")
        let unrelatedPerson = Outsider(name: "Unrelated Successful Edit", gender: "", contactPreference: .sms, contactDetail: "")
        context.insert(unrelatedPerson)
        try context.save()
        try await coordinator.runOneTestPass()
        check(cloud.lastSyncResult?.conflicts == 0 && coordinator.needsAttention,
              "An unrelated scoped success does not hide an existing conflict")
        SyncMockProtocol.server.edit("students", id: conflicted.syncID, fields: ["name": conflicted.name])
        try await coordinator.runOneTestPass(full: true)
        check(cloud.lastError == nil && cloud.lastSyncResult?.conflicts == 0 && !coordinator.needsAttention,
              "A successful full reconciliation clears resolved conflict attention")
        print("Automatic sync: \(checks) checks passed")
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
}
