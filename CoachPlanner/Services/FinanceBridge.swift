import Foundation

/// Bridges CoachPlanner with the sibling MyFinanceTracker app via a shared
/// App Group container.
///
/// Both apps must enable the App Group capability with the identifier below
/// (same Apple Developer team). CoachPlanner writes a JSON envelope to a
/// well-known file inside the shared container; MyFinanceTracker reads that
/// same file from the same container.
///
/// Shared file layout:
///   <group container>/CoachPlannerExport.json
enum FinanceBridge {
    /// Must match the App Group identifier ticked in both apps' entitlements.
    static let appGroupID = "group.com.matthewchew.apptalk"
    static let fileName = "CoachPlannerExport.json"

    /// The JSON envelope sent to MyFinanceTracker. The receiver should decode
    /// this exact shape (paste these structs into the MyFinanceTracker project).
    struct ExportEnvelope: Codable {
        let source: String
        let schemaVersion: Int
        let exportedAt: Date
        let sessions: [SessionPayload]
    }

    struct SessionPayload: Codable {
        let sessionName: String
        let dayOfWeek: String
        let sessionFee: Double
    }

    enum SendResult {
        case success(count: Int, path: String)
        case failure(reason: String)
    }

    static var sharedFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Encodes the sessions into the shared envelope, logs the JSON that is
    /// about to be sent, and writes it to the App Group container.
    static func send(sessions: [SessionPayload], exportedAt: Date) -> SendResult {
        let envelope = ExportEnvelope(
            source: "CoachPlanner",
            schemaVersion: 1,
            exportedAt: exportedAt,
            sessions: sessions
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(envelope) else {
            print("[FinanceBridge] ❌ Failed to encode export envelope.")
            return .failure(reason: "Could not build the JSON payload.")
        }

        // Log the exact JSON being sent so it can be inspected.
        let jsonString = String(data: data, encoding: .utf8) ?? "<unprintable>"
        print("""
        [FinanceBridge] 📤 Sending payload to MyFinanceTracker \
        (App Group: \(appGroupID)):
        \(jsonString)
        """)

        guard let url = sharedFileURL else {
            print("[FinanceBridge] ❌ Shared container URL unavailable — is the App Group capability enabled with \(appGroupID)?")
            return .failure(reason: "App Group container is not available. Check that the App Groups capability is enabled.")
        }

        do {
            try data.write(to: url, options: [.atomic])
            print("[FinanceBridge] ✅ Wrote \(data.count) bytes to \(url.path)")
            return .success(count: sessions.count, path: url.path)
        } catch {
            print("[FinanceBridge] ❌ Write failed: \(error)")
            return .failure(reason: "Could not write to the shared container: \(error.localizedDescription)")
        }
    }
}
