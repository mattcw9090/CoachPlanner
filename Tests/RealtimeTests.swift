import Foundation

@main
struct RealtimeTests {
    static let workspace = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let rowID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let now = Date(timeIntervalSince1970: 1_000)
    static var checks = 0

    static func main() throws {
        try requestConstruction()
        try readinessAndFailures()
        try rowInvalidations()
        try heartbeatDeadlines()
        print("Realtime protocol: \(checks) checks passed")
    }

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError(message) }
    }

    static func object(_ value: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
    }

    static func frame(_ state: SupabaseRealtimeProtocol, event: String, payload: [String: Any], ref: String? = nil, topic: String? = nil) throws -> Data {
        var value: [String: Any] = ["topic": topic ?? state.topic, "event": event, "payload": payload]
        if let ref { value["ref"] = ref }
        return try JSONSerialization.data(withJSONObject: value)
    }

    static func joinReply(_ state: SupabaseRealtimeProtocol, tables: [String] = SupabaseRealtimeProtocol.tables) throws -> Data {
        let changes: [[String: Any]] = tables.enumerated().map { index, table in
            ["id": index + 1, "schema": "public", "table": table, "event": "*",
             "filter": "workspace_id=eq.\(workspace.uuidString.lowercased())"]
        }
        return try frame(state, event: "phx_reply", payload: ["status": "ok", "response": ["postgres_changes": changes]], ref: "1")
    }

    static func ready() throws -> SupabaseRealtimeProtocol {
        var state = SupabaseRealtimeProtocol(workspaceID: workspace, now: now)
        expect(state.receive(try joinReply(state), now: now).isEmpty, "Join alone must not mark PostgreSQL ready")
        let system = try frame(state, event: "system", payload: ["extension": "postgres_changes", "status": "ok"])
        expect(state.receive(system, now: now) == [.connected], "Both confirmations should connect once")
        return state
    }

    static func requestConstruction() throws {
        var state = SupabaseRealtimeProtocol(workspaceID: workspace, now: now)
        let url = SupabaseRealtimeProtocol.socketURL(projectURL: URL(string: "https://example.supabase.co")!, publishableKey: "public+key&suffix")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        expect(components.scheme == "wss", "HTTPS must use secure WebSocket")
        expect(components.path == "/realtime/v1/websocket", "Correct WebSocket endpoint")
        expect(components.queryItems?.first(where: { $0.name == "apikey" })?.value == "public+key&suffix", "API key must survive URL encoding")
        expect(components.queryItems?.first(where: { $0.name == "vsn" })?.value == "1.0.0", "Use the JSON object protocol version")
        expect(SupabaseRealtimeProtocol.socketURL(projectURL: URL(string: "file:///tmp/data")!, publishableKey: "key") == nil, "Reject non-network URL")
        let message = try object(state.joinMessage(token: "example-token"))
        let payload = message["payload"] as! [String: Any]
        let config = payload["config"] as! [String: Any]
        let changes = config["postgres_changes"] as! [[String: Any]]
        expect(changes.count == 5, "Subscribe only to parent tables")
        expect(changes.allSatisfy { $0["filter"] as? String == "workspace_id=eq.\(workspace.uuidString.lowercased())" }, "Every table is workspace-filtered")
        expect(payload["access_token"] as? String == "example-token", "Join carries authenticated JWT")
        expect(message["ref"] as? String == "1" && message["join_ref"] as? String == "1", "Join references match")
        let refresh = try object(state.accessTokenMessage("refreshed-token"))
        expect(refresh["event"] as? String == "access_token", "Refresh uses in-band token update")
        expect((refresh["payload"] as? [String: Any])?["access_token"] as? String == "refreshed-token", "Refresh carries new JWT")
    }

    static func readinessAndFailures() throws {
        var state = try ready()
        let system = try frame(state, event: "system", payload: ["extension": "postgres_changes", "status": "ok"])
        expect(state.receive(system, now: now).isEmpty, "Duplicate ready should not trigger recovery loop")
        expect(state.isConnected, "Connection stays ready")
        var reversed = SupabaseRealtimeProtocol(workspaceID: workspace, now: now)
        expect(reversed.receive(system, now: now).isEmpty, "System ready alone is insufficient")
        expect(reversed.receive(try joinReply(reversed), now: now) == [.connected], "Ready notices may arrive before join response")
        var missing = SupabaseRealtimeProtocol(workspaceID: workspace, now: now)
        expect(missing.receive(try joinReply(missing, tables: ["students"]), now: now) == [.disconnect], "Missing subscriptions fail instead of claiming live sync")
        var duplicate = SupabaseRealtimeProtocol(workspaceID: workspace, now: now)
        expect(duplicate.receive(try joinReply(duplicate, tables: Array(repeating: "students", count: 5)), now: now) == [.disconnect], "Duplicate tables are not five subscriptions")
        for event in ["phx_error", "phx_close"] {
            var failure = try ready()
            let error = try frame(failure, event: event, payload: [:])
            expect(failure.receive(error, now: now) == [.disconnect], "Channel failures must disconnect")
            expect(failure.receive(system, now: now).isEmpty, "Late server messages cannot revive a failed connection")
        }
        var subscriptionError = try ready()
        let error = try frame(subscriptionError, event: "system", payload: ["extension": "postgres_changes", "status": "error", "message": "table not in publication"])
        expect(subscriptionError.receive(error, now: now) == [.disconnect], "A live socket with failed replication is not connected")
        var timeout = SupabaseRealtimeProtocol(workspaceID: workspace, now: now)
        expect(timeout.tick(now: now.addingTimeInterval(20)) == [.disconnect], "An unacknowledged join has a deadline")
        var malformed = try ready()
        expect(malformed.receive(Data("not json".utf8), now: now) == [.disconnect], "Malformed frames fail closed")
    }

    static func changeFrame(_ state: SupabaseRealtimeProtocol, kind: String = "UPDATE", workspaceID: UUID = workspace,
                            id: String? = rowID.uuidString, subscriptionIDs: [Int] = [3], errors: Any = NSNull()) throws -> Data {
        var record: [String: Any] = ["workspace_id": workspaceID.uuidString, "deleted_at": NSNull()]
        if let id { record["id"] = id }
        return try frame(state, event: "postgres_changes", payload: ["ids": subscriptionIDs, "data": [
            "schema": "public", "table": "coaching_sessions", "type": kind,
            "record": kind == "DELETE" ? [:] : record, "old_record": ["id": rowID.uuidString], "errors": errors
        ]])
    }

    static func rowInvalidations() throws {
        var state = try ready()
        expect(state.receive(try changeFrame(state), now: now) == [.change("coaching_sessions", rowID)], "Updates invalidate exactly one parent")
        expect(state.receive(try changeFrame(state, kind: "INSERT"), now: now) == [.change("coaching_sessions", rowID)], "Inserts invalidate their parent")
        expect(state.receive(try changeFrame(state, workspaceID: UUID()), now: now).isEmpty, "Never accept another workspace record")
        expect(state.receive(try changeFrame(state, kind: "DELETE"), now: now) == [.recover], "Hard deletes require authenticated reconciliation")
        expect(state.receive(try changeFrame(state, id: nil), now: now) == [.recover], "Missing identifiers request recovery")
        expect(state.receive(try changeFrame(state, id: "bad-id"), now: now) == [.recover], "Invalid identifiers request recovery")
        expect(state.receive(try changeFrame(state, errors: ["decode error"]), now: now) == [.recover], "Server row errors must not silently lose changes")
        expect(state.receive(try changeFrame(state, errors: [String]()), now: now) == [.change("coaching_sessions", rowID)], "An empty errors array still delivers the targeted change")
        expect(state.receive(try changeFrame(state, subscriptionIDs: [99]), now: now) == [.disconnect], "Mismatched subscription IDs require rejoin")
    }

    static func heartbeatDeadlines() throws {
        var state = try ready()
        expect(state.tick(now: now.addingTimeInterval(19)).isEmpty, "No busy-loop heartbeats")
        let actions = state.tick(now: now.addingTimeInterval(20))
        guard case .send(let heartbeat) = actions.first else { fatalError("Missing heartbeat") }
        let heartbeatObject = try object(heartbeat)
        expect(heartbeatObject["topic"] as? String == "phoenix" && heartbeatObject["event"] as? String == "heartbeat", "Heartbeat uses Phoenix topic")
        expect(heartbeatObject["join_ref"] is NSNull, "Heartbeat has no channel join reference")
        let ref = heartbeatObject["ref"] as! String
        let unrelatedReply = try frame(state, event: "phx_reply", payload: ["status": "ok"], ref: "999", topic: "phoenix")
        expect(state.receive(unrelatedReply, now: now.addingTimeInterval(21)).isEmpty, "Unrelated reply is ignored")
        expect(state.tick(now: now.addingTimeInterval(30)) == [.disconnect], "Unrelated replies must not satisfy the heartbeat deadline")

        var healthy = try ready()
        guard case .send(let healthyHeartbeat) = healthy.tick(now: now.addingTimeInterval(20)).first else { fatalError("Missing heartbeat") }
        let healthyRef = try object(healthyHeartbeat)["ref"] as! String
        let reply = try frame(healthy, event: "phx_reply", payload: ["status": "ok"], ref: healthyRef, topic: "phoenix")
        expect(healthy.receive(reply, now: now.addingTimeInterval(21)).isEmpty, "Matching heartbeat is acknowledged")
        expect(healthy.tick(now: now.addingTimeInterval(30)).isEmpty, "Acknowledged heartbeat must not expire")
        expect(healthy.tick(now: now.addingTimeInterval(40)).count == 1, "Next heartbeat continues after acknowledgement")
        expect(ref == healthyRef, "Fresh connections reset reference sequence")
    }
}
