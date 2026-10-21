import Combine
import Foundation
import Network
import SwiftData

/// Keeps edits made during a request separate from that request's acknowledgement.
/// Persisting the union also makes an interrupted upload safe to retry after launch.
struct CloudSyncOutbox {
    private(set) var pending: CloudSyncScope
    private(set) var inFlight = CloudSyncScope()

    init(pending: CloudSyncScope = CloudSyncScope()) { self.pending = pending }

    var durableScope: CloudSyncScope {
        var scope = pending
        scope.formUnion(inFlight)
        return scope
    }

    mutating func enqueue(_ scope: CloudSyncScope) { pending.formUnion(scope) }

    mutating func begin() -> CloudSyncScope {
        precondition(inFlight.isEmpty)
        inFlight = pending
        pending = CloudSyncScope()
        return inFlight
    }

    mutating func finish(succeeded: Bool) {
        if !succeeded { pending.formUnion(inFlight) }
        inFlight = CloudSyncScope()
    }
}

enum MoveCoachingWeekFailure: Error, Equatable {
    case offline
    case signedOut
    case refreshFailed
    case blocked(String)

    var alertTitle: String {
        switch self {
        case .refreshFailed: return "Couldn't Refresh Sessions"
        default: return "Couldn't Move Sessions"
        }
    }

    var alertMessage: String {
        switch self {
        case .offline:
            return "Moving sessions needs an internet connection."
        case .signedOut:
            return "Sign in before moving sessions."
        case .refreshFailed:
            return "Sessions were moved online, but this device could not refresh. Use Sync cloud data, then open next week."
        case .blocked(let message):
            return message
        }
    }
}

enum SyncAttentionPrompt: Equatable {
    case signIn
    case conflict
    case uploadFailed
    case saveFailed

    var title: String {
        switch self {
        case .signIn:
            return "Sign in to keep this device in sync"
        case .conflict:
            return "Review sync conflicts"
        case .uploadFailed:
            return "Saved changes are not uploading"
        case .saveFailed:
            return "Changes could not be saved on this device"
        }
    }

    var systemImage: String {
        switch self {
        case .signIn: return "person.crop.circle.badge.exclamationmark"
        case .conflict: return "exclamationmark.triangle.fill"
        case .uploadFailed: return "icloud.slash"
        case .saveFailed: return "externaldrive.badge.exclamationmark"
        }
    }
}

@MainActor
final class SupabaseAutoSync: ObservableObject {
    static let shared = SupabaseAutoSync()
    static let preferenceKey = "automaticCloudSync"

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.preferenceKey)
            if isEnabled { requestRecovery() } else { stopRealtime() }
            updateStatus()
        }
    }
    @Published private(set) var status = "Waiting to sync"
    @Published private(set) var needsAttention = false
    @Published private(set) var attentionPrompt: SyncAttentionPrompt?
    @Published private(set) var localSaveError: String?

    /// Sync errors worth showing in Settings. A dropped connection retries quietly.
    var reportedSyncError: String? {
        guard let error = cloud.lastError, !isConnectivityMessage(error) else { return nil }
        return error
    }

    private let cloud: SupabaseCloud
    private let defaults: UserDefaults
    private let realtime = SupabaseRealtimeClient()
    private let monitor = NWPathMonitor()
    private let outboxKey: String
    private var outbox: CloudSyncOutbox
    private weak var context: ModelContext?
    private var observations = Set<AnyCancellable>()
    private var timer: Timer?
    private var capturedSave = CloudSyncScope()
    private var isActive = false
    private var isOnline = true
    private var isRunning = false
    private var fullSyncRequested = false
    private var manualSyncRequested = false
    private var lastEnqueue = Date.distantPast
    private var firstEnqueue: Date?
    private var retryAfter = Date.distantPast
    private var retryDelay: TimeInterval = 2
    private var lastRecovery = Date.distantPast
    private var hasCompletedSync = false
    private var moveInProgress = false
    private var consecutiveUploadFailures = 0
    private static let repeatedUploadFailureThreshold = 3
    private var hasUnresolvedConflicts: Bool { !cloud.conflicts.isEmpty }
    private var realtimeState = SupabaseRealtimeClient.State.disconnected
    private var connectionTask: Task<Void, Never>?
    private var nextConnectionAttempt = Date.distantPast
    private var connectionRetryDelay: TimeInterval = 2
    private var lastTokenUpdate = Date.distantPast
    private var connectionGeneration = 0

    init(cloud: SupabaseCloud? = nil, defaults: UserDefaults = .standard) {
        self.cloud = cloud ?? .shared
        self.defaults = defaults
        outboxKey = "CoachPlanner.pendingSync.\(SupabaseConfiguration.workspaceID.uuidString)"
        let saved = defaults.data(forKey: outboxKey).flatMap { try? JSONDecoder().decode(CloudSyncScope.self, from: $0) }
        outbox = CloudSyncOutbox(pending: saved ?? CloudSyncScope())
        // Keep the user's existing opt-out from automatic foreground sync.
        isEnabled = defaults.object(forKey: Self.preferenceKey) as? Bool
            ?? defaults.object(forKey: "autoSyncOnLaunch") as? Bool ?? true
    }

    func attach(to context: ModelContext, active: Bool) {
        if self.context !== context {
            self.context = context
            observations.removeAll()
            NotificationCenter.default.publisher(for: ModelContext.willSave, object: context)
                .sink { [weak self] _ in self?.willSave() }.store(in: &observations)
            NotificationCenter.default.publisher(for: ModelContext.didSave, object: context)
                .sink { [weak self] _ in self?.didSave() }.store(in: &observations)
            cloud.$isSignedIn.removeDuplicates().sink { [weak self] signedIn in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if signedIn {
                        self.consecutiveUploadFailures = 0
                        self.requestRecovery()
                    } else {
                        self.stopRealtime()
                    }
                    self.updateStatus()
                }
            }.store(in: &observations)
            cloud.$conflicts.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateStatus() }
            }.store(in: &observations)
            cloud.$lastError.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateStatus() }
            }.store(in: &observations)
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            monitor.pathUpdateHandler = { [weak self] path in
                let connected = path.status == .satisfied
                Task { @MainActor [weak self] in self?.networkChanged(connected) }
            }
            monitor.start(queue: DispatchQueue(label: "CoachPlanner.sync.connectivity"))
        }
        setActive(active)
    }

    func setActive(_ active: Bool) {
        let resumed = active && !isActive
        isActive = active
        if resumed { requestRecovery() }
        if !active {
            flushLocalChanges()
            stopRealtime()
        }
        updateStatus()
    }

    func syncNow() {
        manualSyncRequested = true
        requestRecovery()
        tick()
    }

    /// Uploads unsynced edits, asks the database to move one coaching week, then downloads
    /// the result. Local sessions are not rewritten if the reset cannot be completed.
    func moveCoachingWeek(from weekStart: Date, in context: ModelContext) async -> Result<Int, MoveCoachingWeekFailure> {
        guard cloud.isSignedIn else { return .failure(.signedOut) }
        guard isOnline else { return .failure(.offline) }
        guard !moveInProgress else {
            return .failure(.blocked("Sessions were not moved. A move is already in progress."))
        }
        let deadline = Date().addingTimeInterval(30)
        while isRunning || cloud.isSyncing {
            if Date() >= deadline {
                return .failure(.blocked("Sessions were not moved. Sync is still running. Try again in a moment."))
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard cloud.isSignedIn else { return .failure(.signedOut) }
            guard isOnline else { return .failure(.offline) }
        }
        guard outbox.inFlight.isEmpty else {
            return .failure(.blocked("Sessions were not moved. Sync is still running. Try again in a moment."))
        }

        moveInProgress = true
        isRunning = true
        updateStatus()
        defer {
            moveInProgress = false
            isRunning = false
            updateStatus()
        }

        flushLocalChanges(in: context)
        if let localSaveError {
            return .failure(.blocked("Sessions were not moved. \(localSaveError)"))
        }
        if let failure = await uploadPendingEdits(in: context) {
            return .failure(failure)
        }
        guard cloud.isSignedIn else { return .failure(.signedOut) }
        guard isOnline else { return .failure(.offline) }

        let moved: Int
        do {
            moved = try await cloud.resetCoachingWeek(from: weekStart)
        } catch {
            if !cloud.isSignedIn || error.localizedDescription.lowercased().contains("sign in") {
                return .failure(.signedOut)
            }
            if isConnectivityError(error) { return .failure(.offline) }
            return .failure(.blocked("Sessions were not moved. \(error.localizedDescription)"))
        }

        await cloud.syncAll(in: context)
        guard cloud.lastError == nil else { return .failure(.refreshFailed) }
        await settleOutbox(in: context)
        return .success(moved)
    }

    private func requestRecovery() {
        fullSyncRequested = true
        retryAfter = .distantPast
        nextConnectionAttempt = .distantPast
    }

    private func networkChanged(_ connected: Bool) {
        let reconnected = connected && !isOnline
        isOnline = connected
        if reconnected { requestRecovery() }
        if !connected { stopRealtime() }
        updateStatus()
    }

    private func willSave() {
        guard let context else { return }
        // SwiftData applies inverse/cascade removals during the save. Capture
        // those owning sessions while the deleted person's links still exist.
        let models = context.changedModelsArray + context.insertedModelsArray + context.deletedModelsArray
            + Self.parentsAffectedByDeletion(context.deletedModelsArray)
        capturedSave = Self.scope(for: models)
        if !SyncTimestamping.isApplyingRemoteChange {
            let now = Date()
            for model in models {
                Self.markEdited(model as? SyncTimestamped, at: now)
                // Relationship-only edits must also advance the owning local record.
                if let week = model as? StudentHiddenWeek { Self.markEdited(week.student, at: now) }
                if let attendance = model as? SocialAttendance { Self.markEdited(attendance.session, at: now) }
                if let hidden = model as? SocialHiddenPerson { Self.markEdited(hidden.session, at: now) }
                if let confirmation = model as? SessionStudentConfirmation { Self.markEdited(confirmation.session, at: now) }
            }
        }
    }

    private static func markEdited(_ model: SyncTimestamped?, at now: Date) {
        guard let model else { return }
        // Device clocks can lag the server. A local edit must still be newer
        // than the acknowledged version for concurrent-edit detection.
        model.updatedAt = max(now, model.lastSyncedAt?.addingTimeInterval(0.002) ?? now)
    }

    private func didSave() {
        // Include sync-originated saves: a UI edit can arrive while a request is
        // suspended and be persisted by that save. One scoped no-op pass settles
        // server acknowledgements without dropping those overlapping local edits.
        enqueue(capturedSave)
        capturedSave = CloudSyncScope()
        localSaveError = nil
    }

    private func enqueue(_ scope: CloudSyncScope) {
        guard !scope.isEmpty else { return }
        outbox.enqueue(scope)
        persistOutbox()
        if firstEnqueue == nil { firstEnqueue = Date() }
        lastEnqueue = Date()
        updateStatus()
    }

    private func persistOutbox() {
        if let data = try? JSONEncoder().encode(outbox.durableScope) {
            defaults.set(data, forKey: outboxKey)
        }
    }

    private func flushLocalChanges() {
        guard let context else { return }
        flushLocalChanges(in: context)
    }

    private func flushLocalChanges(in context: ModelContext) {
        guard context.hasChanges, !cloud.isSyncing else { return }
        do {
            try context.save()
            localSaveError = nil
        } catch {
            localSaveError = "Changes could not be saved on this device: \(error.localizedDescription)"
        }
    }

    /// Runs the normal sync upload until queued edits have been pushed.
    private func uploadPendingEdits(in context: ModelContext) async -> MoveCoachingWeekFailure? {
        await cloud.syncAll(in: context)
        if let failure = failureAfterUpload() { return failure }
        outbox.enqueue(cloud.deferredChanges)
        persistOutbox()
        var passes = 0
        while !outbox.pending.isEmpty && passes < 3 {
            passes += 1
            guard outbox.inFlight.isEmpty else {
                return .blocked("Sessions were not moved. Sync is still running. Try again in a moment.")
            }
            let scope = outbox.begin()
            persistOutbox()
            await cloud.syncChanges(scope, in: context)
            let succeeded = cloud.lastError == nil && cloud.conflicts.isEmpty
            outbox.finish(succeeded: succeeded)
            outbox.enqueue(cloud.deferredChanges)
            persistOutbox()
            if let failure = failureAfterUpload() { return failure }
        }
        if !outbox.pending.isEmpty {
            return .blocked("Sessions were not moved. This device still has unsynced edits. Try again once sync finishes.")
        }
        return nil
    }

    /// Best-effort queue settle after the moved week has already downloaded.
    private func settleOutbox(in context: ModelContext) async {
        outbox.enqueue(cloud.deferredChanges)
        persistOutbox()
        var passes = 0
        while !outbox.pending.isEmpty && passes < 3 && cloud.lastError == nil {
            passes += 1
            guard outbox.inFlight.isEmpty else { return }
            let scope = outbox.begin()
            persistOutbox()
            await cloud.syncChanges(scope, in: context)
            outbox.finish(succeeded: cloud.lastError == nil)
            outbox.enqueue(cloud.deferredChanges)
            persistOutbox()
        }
    }

    private func failureAfterUpload() -> MoveCoachingWeekFailure? {
        if !cloud.isSignedIn { return .signedOut }
        if !isOnline { return .offline }
        if let lastError = cloud.lastError {
            return isConnectivityMessage(lastError) ? .offline : .blocked("Sessions were not moved. \(lastError)")
        }
        if !cloud.conflicts.isEmpty {
            return .blocked("Sessions were not moved. Review sync conflicts in Settings, then try again.")
        }
        return nil
    }

    private func isConnectivityError(_ error: Error) -> Bool {
        if !isOnline { return true }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                break
            }
        }
        return isConnectivityMessage(error.localizedDescription)
    }

    private func isConnectivityMessage(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("internet connection")
            || text.contains("appears to be offline")
            || text.contains("network connection was lost")
            || text.contains("not connected to the internet")
            || text.contains("timed out")
            || text.contains("could not connect")
            || text.contains("cannot connect")
    }

    private func tick() {
        guard isActive else { return }
        flushLocalChanges()
        updateStatus()
        guard cloud.isSignedIn, isOnline, isEnabled || manualSyncRequested else { return }
        if isEnabled { maintainRealtime() }
        guard !isRunning, !cloud.isSyncing, localSaveError == nil,
              let context, !context.hasChanges, Date() >= retryAfter else { return }
        // Recovery also covers rare missed notifications. When the live channel
        // is unavailable, fall back to a modest foreground refresh interval.
        let recoveryInterval: TimeInterval = realtimeState == .connected ? 300 : 30
        if isEnabled && Date().timeIntervalSince(lastRecovery) >= recoveryInterval {
            fullSyncRequested = true
        }
        guard fullSyncRequested || !outbox.pending.isEmpty else { return }
        let now = Date()
        if !manualSyncRequested, !fullSyncRequested,
           now.timeIntervalSince(lastEnqueue) < 0.5,
           now.timeIntervalSince(firstEnqueue ?? now) < 2 { return }

        let full = fullSyncRequested
        fullSyncRequested = false
        manualSyncRequested = false
        let scope = outbox.begin()
        firstEnqueue = nil
        persistOutbox()
        isRunning = true
        updateStatus()
        Task { [weak self] in
            guard let self else { return }
            if full { await self.cloud.syncAll(in: context) }
            else { await self.cloud.syncChanges(scope, in: context) }
            let succeeded = self.cloud.lastError == nil
            self.outbox.finish(succeeded: succeeded)
            self.recordUploadAttempt(succeeded: succeeded)
            self.outbox.enqueue(self.cloud.deferredChanges)
            self.persistOutbox()
            self.isRunning = false
            if succeeded {
                self.hasCompletedSync = true
                self.retryDelay = 2
                if full { self.lastRecovery = Date() }
            } else {
                self.fullSyncRequested = self.fullSyncRequested || full
                self.retryAfter = Date().addingTimeInterval(self.retryDelay)
                self.retryDelay = min(self.retryDelay * 2, 60)
            }
            self.updateStatus()
        }
    }

    private func maintainRealtime() {
        guard connectionTask == nil else { return }
        let connected = realtimeState == .connected
        guard connected ? Date().timeIntervalSince(lastTokenUpdate) >= 240
                        : realtimeState == .disconnected && Date() >= nextConnectionAttempt else { return }
        let generation = connectionGeneration
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.connectionGeneration { self.connectionTask = nil } }
            do {
                let token = try await self.cloud.realtimeAccessToken()
                guard !Task.isCancelled, generation == self.connectionGeneration,
                      self.isActive, self.isEnabled, self.cloud.isSignedIn else { return }
                self.lastTokenUpdate = Date()
                if connected {
                    self.realtime.updateAccessToken(token)
                } else {
                    self.realtime.start(
                        token: token,
                        workspaceID: SupabaseConfiguration.workspaceID,
                        projectURL: SupabaseConfiguration.projectURL,
                        publishableKey: SupabaseConfiguration.publishableKey,
                        onChange: { [weak self] table, id in
                            var scope = CloudSyncScope()
                            scope.insert(table: table, id: id)
                            self?.enqueue(scope)
                        },
                        onStatus: { [weak self] state in self?.connectionChanged(state) },
                        onRecoveryNeeded: { [weak self] in self?.requestRecovery() }
                    )
                }
            } catch {
                guard generation == self.connectionGeneration else { return }
                self.connectionChanged(.disconnected)
            }
        }
    }

    private func connectionChanged(_ state: SupabaseRealtimeClient.State) {
        let wasConnected = realtimeState == .connected
        realtimeState = state
        if state == .connected {
            connectionRetryDelay = 2
            // Subscribe before recovery so changes during the download stay queued.
            if !wasConnected { fullSyncRequested = true }
        } else if state == .disconnected {
            nextConnectionAttempt = Date().addingTimeInterval(connectionRetryDelay)
            connectionRetryDelay = min(connectionRetryDelay * 2, 60)
        }
        updateStatus()
    }

    private func stopRealtime() {
        connectionGeneration += 1
        connectionTask?.cancel()
        connectionTask = nil
        realtime.stop()
        realtimeState = .disconnected
    }

    private func recordUploadAttempt(succeeded: Bool) {
        if succeeded {
            consecutiveUploadFailures = 0
            return
        }
        guard isOnline, let lastError = cloud.lastError else { return }
        if isConnectivityMessage(lastError) || isAuthenticationMessage(lastError) { return }
        consecutiveUploadFailures += 1
    }

    private func isAuthenticationMessage(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("sign in")
            || text.contains("jwt")
            || text.contains("invalid claim")
            || text.contains("refresh token")
            || text.contains("session expired")
            || text.contains("not authenticated")
            || text.contains("401")
    }

    private func updateStatus() {
        needsAttention = localSaveError != nil || cloud.lastError != nil || hasUnresolvedConflicts
            || cloud.lastSyncResult?.needsAttention == true
        attentionPrompt = currentAttentionPrompt()
        if localSaveError != nil { status = "Could not save changes" }
        else if !cloud.isSignedIn { status = "Sign in to sync" }
        else if !isOnline { status = "Offline · saved on this device" }
        else if isRunning || cloud.isSyncing { status = "Syncing…" }
        else if hasUnresolvedConflicts { status = "Conflicting edits · see Settings" }
        else if needsAttention { status = "Sync needs attention" }
        else if !isEnabled { status = outbox.pending.isEmpty ? "Automatic sync off" : "Saved on this device" }
        else if !outbox.pending.isEmpty || fullSyncRequested { status = "Waiting to sync…" }
        else if !hasCompletedSync { status = "Connecting…" }
        else if realtimeState != .connected { status = "Synced · live updates reconnecting" }
        else { status = "Synced" }
    }

    /// Visible only when Matthew has to act. Ordinary syncing, a finished sync,
    /// and a short offline retry stay quiet.
    private func currentAttentionPrompt() -> SyncAttentionPrompt? {
        if !cloud.isSignedIn || cloud.lastError.map(isAuthenticationMessage) == true {
            return .signIn
        }
        if hasUnresolvedConflicts { return .conflict }
        if localSaveError != nil { return .saveFailed }
        if isOnline,
           consecutiveUploadFailures >= Self.repeatedUploadFailureThreshold,
           cloud.lastError != nil {
            return .uploadFailed
        }
        return nil
    }

    static func scope(for models: [any PersistentModel]) -> CloudSyncScope {
        var scope = CloudSyncScope()
        for model in models {
            switch model {
            case let student as Student:
                scope.students.insert(student.syncID)
            case let outsider as Outsider:
                scope.outsiders.insert(outsider.syncID)
            case let session as CoachingSession:
                scope.coachingSessions.insert(session.syncID)
                for student in session.studentList where student.lastSyncedAt == nil {
                    scope.students.insert(student.syncID)
                }
            case let booking as CourtBooking:
                scope.courtBookings.insert(booking.syncID)
            case let session as SocialSession:
                scope.socialSessions.insert(session.syncID)
                for student in session.studentList where student.lastSyncedAt == nil {
                    scope.students.insert(student.syncID)
                }
                for attendance in session.attendanceList {
                    if let student = attendance.student, student.lastSyncedAt == nil { scope.students.insert(student.syncID) }
                    if let outsider = attendance.outsider, outsider.lastSyncedAt == nil { scope.outsiders.insert(outsider.syncID) }
                }
                for hidden in session.hiddenPersonList {
                    if let student = hidden.student, student.lastSyncedAt == nil { scope.students.insert(student.syncID) }
                    if let outsider = hidden.outsider, outsider.lastSyncedAt == nil { scope.outsiders.insert(outsider.syncID) }
                }
            case let week as StudentHiddenWeek:
                if let student = week.student { scope.students.insert(student.syncID) }
            case let attendance as SocialAttendance:
                if let session = attendance.session { scope.socialSessions.insert(session.syncID) }
            case let hidden as SocialHiddenPerson:
                if let session = hidden.session { scope.socialSessions.insert(session.syncID) }
            case let confirmation as SessionStudentConfirmation:
                if let session = confirmation.session {
                    scope.coachingSessions.insert(session.syncID)
                    for student in session.studentList where student.lastSyncedAt == nil {
                        scope.students.insert(student.syncID)
                    }
                }
            default: break
            }
        }
        return scope
    }

    private static func parentsAffectedByDeletion(_ models: [any PersistentModel]) -> [any PersistentModel] {
        var parents: [any PersistentModel] = []
        for model in models {
            if let student = model as? Student {
                parents.append(contentsOf: student.sessions ?? [])
                parents.append(contentsOf: student.socialSessions ?? [])
                parents.append(contentsOf: student.legacyHiddenSocialSessions ?? [])
                parents.append(contentsOf: (student.socialHiddenRecords ?? []).compactMap(\.session))
                parents.append(contentsOf: (student.socialAttendances ?? []).compactMap(\.session))
                parents.append(contentsOf: (student.sessionConfirmations ?? []).compactMap(\.session))
            } else if let confirmation = model as? SessionStudentConfirmation {
                if let session = confirmation.session { parents.append(session) }
            } else if let outsider = model as? Outsider {
                parents.append(contentsOf: outsider.legacyHiddenSocialSessions ?? [])
                parents.append(contentsOf: (outsider.socialHiddenRecords ?? []).compactMap(\.session))
                parents.append(contentsOf: (outsider.socialAttendances ?? []).compactMap(\.session))
            }
        }
        return parents
    }
}
