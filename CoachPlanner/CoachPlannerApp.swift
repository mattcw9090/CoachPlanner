import SwiftData
import SwiftUI

@main
struct CoachPlannerApp: App {
    let modelContainer: ModelContainer

    init() {
        CoachPlannerApp.modelContainer = Self.makeContainer()
        self.modelContainer = CoachPlannerApp.modelContainer
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
    }

    // Exposed so non-View code (e.g. backups) can reach the same container.
    static private(set) var modelContainer: ModelContainer!

    /// The schema shared across the app.
    static let schema = Schema([
        Student.self,
        CoachingSession.self,
        CourtBooking.self
    ])

    /// Builds the SwiftData container.
    ///
    /// The store lives inside the **App Group container**
    /// (`group.com.matthewchew.apptalk`) rather than the app's private
    /// container. The App Group container persists across app reinstalls and
    /// signing-identity changes, so re-provisioning the app (e.g. when adding
    /// capabilities or switching teams) no longer wipes user data.
    private static func makeContainer() -> ModelContainer {
        let groupConfig = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(FinanceBridge.appGroupID)
        )

        do {
            return try ModelContainer(for: schema, configurations: [groupConfig])
        } catch {
            // If the App Group container is unavailable (e.g. the capability is
            // missing in this build), fail loudly rather than silently writing
            // to a different location and splitting the user's data.
            fatalError("""
            Could not open the CoachPlanner store in the App Group container \
            \(FinanceBridge.appGroupID). Verify the App Groups capability is \
            enabled for this target. Underlying error: \(error)
            """)
        }
    }
}
