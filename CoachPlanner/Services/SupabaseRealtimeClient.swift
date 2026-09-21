import Foundation

/// Notifications are invalidations only. The sync service still reads authorized
/// rows over HTTP and applies its existing version/conflict checks.
@MainActor
final class SupabaseRealtimeClient {
    enum State: Equatable { case connecting, connected, disconnected }

    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var connection: SupabaseRealtimeProtocol?
    private var generation = UUID()
    private var onChange: ((String, UUID) -> Void)?
    private var onStatus: ((State) -> Void)?
    private var onRecoveryNeeded: (() -> Void)?

    init(session: URLSession = .shared) { self.session = session }

    /// Reconnection and refreshed credentials belong to the sync coordinator.
    /// A socket failure produces one disconnected status, never a retry loop.
    func start(
        token: String, workspaceID: UUID, projectURL: URL, publishableKey: String,
        onChange: @escaping (String, UUID) -> Void,
        onStatus: @escaping (State) -> Void,
        onRecoveryNeeded: @escaping () -> Void = {}
    ) {
        stop(notify: false)
        self.onChange = onChange
        self.onStatus = onStatus
        self.onRecoveryNeeded = onRecoveryNeeded
        let current = generation
        guard let url = SupabaseRealtimeProtocol.socketURL(projectURL: projectURL, publishableKey: publishableKey) else {
            fail(generation: current)
            return
        }
        let protocolState = SupabaseRealtimeProtocol(workspaceID: workspaceID, now: Date())
        connection = protocolState
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.maximumMessageSize = 2 * 1024 * 1024
        socket.resume()
        onStatus(.connecting)
        guard generation == current else { return }

        receiver = Task { [weak self] in
            do {
                let join = try protocolState.joinMessage(token: token)
                try await socket.send(.string(join))
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.generation == current else { return }
                    let data: Data
                    switch message {
                    case .string(let value): data = Data(value.utf8)
                    case .data(let value): data = value
                    @unknown default: self.fail(generation: current); return
                    }
                    let actions = self.connection?.receive(data, now: Date()) ?? []
                    await self.perform(actions, socket: socket, generation: current)
                }
            } catch {
                self?.fail(generation: current)
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self, self.generation == current else { return }
                let actions = self.connection?.tick(now: Date()) ?? []
                await self.perform(actions, socket: socket, generation: current)
            }
        }
    }

    func updateAccessToken(_ token: String) {
        guard let socket, let message = try? connection?.accessTokenMessage(token) else { return }
        let current = generation
        Task { [weak self] in
            do { try await socket.send(.string(message)) }
            catch { self?.fail(generation: current) }
        }
    }

    func stop() { stop(notify: true) }

    private func stop(notify: Bool) {
        let callback = onStatus
        generation = UUID()
        receiver?.cancel()
        timer?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        receiver = nil
        timer = nil
        socket = nil
        connection = nil
        onChange = nil
        onStatus = nil
        onRecoveryNeeded = nil
        if notify { callback?(.disconnected) }
    }

    private func fail(generation expected: UUID) {
        guard expected == generation else { return }
        stop(notify: true)
    }

    private func perform(_ actions: [SupabaseRealtimeProtocol.Action], socket: URLSessionWebSocketTask, generation expected: UUID) async {
        for action in actions {
            guard generation == expected else { return }
            switch action {
            case .connected: onStatus?(.connected)
            case .change(let table, let id): onChange?(table, id)
            case .recover: onRecoveryNeeded?()
            case .disconnect: fail(generation: expected)
            case .send(let message):
                do { try await socket.send(.string(message)) }
                catch { fail(generation: expected) }
            }
        }
    }
}

/// Phoenix v1 JSON protocol, isolated from the socket so readiness, filtering,
/// failure paths and heartbeat deadlines can be tested without cloud data.
struct SupabaseRealtimeProtocol {
    enum Action: Equatable {
        case connected
        case change(String, UUID)
        case recover
        case disconnect
        case send(String)
    }

    static let tables = ["students", "outsiders", "coaching_sessions", "court_bookings", "social_sessions"]
    let workspaceID: UUID
    let topic: String
    private let joinReference = "1"
    private var nextReference = 2
    private var subscriptions: [String: Int] = [:]
    private var postgresReady = false
    private(set) var isConnected = false
    private var failed = false
    private let joinDeadline: Date
    private var nextHeartbeat: Date
    private var pendingHeartbeat: (reference: String, deadline: Date)?

    init(workspaceID: UUID, now: Date) {
        self.workspaceID = workspaceID
        topic = "realtime:coachplanner-\(workspaceID.uuidString.lowercased())"
        joinDeadline = now.addingTimeInterval(20)
        nextHeartbeat = now.addingTimeInterval(20)
    }

    static func socketURL(projectURL: URL, publishableKey: String) -> URL? {
        guard var parts = URLComponents(url: projectURL, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, ["https", "http"].contains(scheme),
              parts.host != nil, !publishableKey.isEmpty else { return nil }
        parts.scheme = scheme == "https" ? "wss" : "ws"
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = (parts.path.isEmpty ? "" : "/" + parts.path) + "/realtime/v1/websocket"
        parts.queryItems = [URLQueryItem(name: "apikey", value: publishableKey), URLQueryItem(name: "vsn", value: "1.0.0")]
        parts.fragment = nil
        return parts.url
    }

    func joinMessage(token: String) throws -> String {
        let changes = Self.tables.map { ["event": "*", "schema": "public", "table": $0, "filter": workspaceFilter] }
        return try encode(event: "phx_join", topic: topic, reference: joinReference, joinReference: joinReference, payload: [
            "access_token": token,
            "config": ["broadcast": ["ack": false, "self": false], "presence": ["enabled": false],
                       "private": false, "postgres_changes": changes]
        ])
    }

    mutating func accessTokenMessage(_ token: String) throws -> String {
        try encode(event: "access_token", topic: topic, reference: reference(), joinReference: joinReference,
                   payload: ["access_token": token])
    }

    mutating func tick(now: Date) -> [Action] {
        guard !failed else { return [] }
        if (!isConnected && now >= joinDeadline) || (pendingHeartbeat.map { now >= $0.deadline } ?? false) {
            return disconnect()
        }
        guard now >= nextHeartbeat, pendingHeartbeat == nil else { return [] }
        let ref = reference()
        pendingHeartbeat = (ref, now.addingTimeInterval(10))
        nextHeartbeat = now.addingTimeInterval(20)
        guard let message = try? encode(event: "heartbeat", topic: "phoenix", reference: ref, joinReference: nil, payload: [:]) else {
            return disconnect()
        }
        return [.send(message)]
    }

    mutating func receive(_ data: Data, now: Date) -> [Action] {
        guard !failed else { return [] }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = message["event"] as? String,
              let incomingTopic = message["topic"] as? String,
              let payload = message["payload"] as? [String: Any] else { return disconnect() }
        let ref = message["ref"] as? String
        if incomingTopic == "phoenix", event == "phx_reply", ref == pendingHeartbeat?.reference, pendingHeartbeat != nil {
            guard payload["status"] as? String == "ok" else { return disconnect() }
            pendingHeartbeat = nil
            return []
        }
        guard incomingTopic == topic else { return [] }
        // A delayed response for a previous join must never revive this channel.
        if let incomingJoin = message["join_ref"] as? String, incomingJoin != joinReference { return [] }
        switch event {
        case "phx_close", "phx_error": return disconnect()
        case "phx_reply":
            guard ref == joinReference else {
                return payload["status"] as? String == "error" ? disconnect() : []
            }
            guard payload["status"] as? String == "ok",
                  let response = payload["response"] as? [String: Any],
                  let changes = response["postgres_changes"] as? [[String: Any]],
                  changes.count == Self.tables.count else { return disconnect() }
            var confirmed: [String: Int] = [:]
            for item in changes {
                guard let table = item["table"] as? String, Self.tables.contains(table), confirmed[table] == nil,
                      item["schema"] as? String == "public", item["event"] as? String == "*",
                      let id = item["id"] as? Int,
                      item["filter"] == nil || item["filter"] as? String == workspaceFilter else { return disconnect() }
                confirmed[table] = id
            }
            guard Set(confirmed.values).count == Self.tables.count else { return disconnect() }
            subscriptions = confirmed
            return becomeReadyIfPossible()
        case "system":
            guard payload["status"] as? String == "ok" else { return disconnect() }
            if payload["extension"] as? String == "postgres_changes" {
                postgresReady = true
                return becomeReadyIfPossible()
            }
            return []
        case "postgres_changes":
            guard !subscriptions.isEmpty,
                  let row = payload["data"] as? [String: Any],
                  row["schema"] as? String == "public", let table = row["table"] as? String,
                  let subscriptionID = subscriptions[table],
                  let ids = payload["ids"] as? [Int], ids.contains(subscriptionID),
                  Set(ids).isSubset(of: Set(subscriptions.values)) else { return disconnect() }
            if let errors = row["errors"], !(errors is NSNull),
               !((errors as? [Any])?.isEmpty ?? false) { return [.recover] }
            // DELETE payloads may lack workspace_id and bypass server filters.
            // Never apply them directly. A full, authenticated read reconciles.
            guard let kind = row["type"] as? String, ["INSERT", "UPDATE"].contains(kind) else { return [.recover] }
            guard let record = row["record"] as? [String: Any],
                  let workspace = record["workspace_id"] as? String,
                  let rowWorkspace = UUID(uuidString: workspace) else { return [.recover] }
            guard rowWorkspace == workspaceID else { return [] }
            guard let rawID = record["id"] as? String, let id = UUID(uuidString: rawID) else { return [.recover] }
            return [.change(table, id)]
        default: return []
        }
    }

    private var workspaceFilter: String { "workspace_id=eq.\(workspaceID.uuidString.lowercased())" }

    private mutating func becomeReadyIfPossible() -> [Action] {
        guard postgresReady, subscriptions.count == Self.tables.count, !isConnected else { return [] }
        isConnected = true
        return [.connected]
    }

    private mutating func disconnect() -> [Action] {
        failed = true
        isConnected = false
        return [.disconnect]
    }

    private mutating func reference() -> String {
        defer { nextReference += 1 }
        return String(nextReference)
    }

    private func encode(event: String, topic: String, reference: String, joinReference: String?, payload: [String: Any]) throws -> String {
        var message: [String: Any] = ["topic": topic, "event": event, "payload": payload, "ref": reference]
        message["join_ref"] = joinReference.map { $0 as Any } ?? NSNull()
        return String(decoding: try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), as: UTF8.self)
    }
}
