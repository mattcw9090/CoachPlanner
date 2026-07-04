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
        StudentHiddenWeek.self,
        Outsider.self,
        CoachingSession.self,
        CourtBooking.self,
        SocialSession.self,
        SocialAttendance.self
    ])

    /// Builds the SwiftData container.
    ///
    /// The store lives inside the **App Group container**
    /// (`group.com.matthewchew.apptalk`) rather than the app's private
    /// container. The App Group container persists across app reinstalls and
    /// signing-identity changes, so re-provisioning the app (e.g. when adding
    /// capabilities or switching teams) no longer wipes user data.
    private static func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(
            schema: schema,
            groupContainer: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not open the CoachPlanner store: \(error)")
        }
    }
}
