import SwiftData
import SwiftUI

@main
struct CoachPlannerApp: App {
    let modelContainer: ModelContainer

    init() {
        let container = Self.makeContainer()
        self.modelContainer = container
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
    }

    static let modelTypes: [any PersistentModel.Type] = [
        Student.self,
        StudentHiddenWeek.self,
        Outsider.self,
        CoachingSession.self,
        CourtBooking.self,
        SocialSession.self,
        SocialHiddenPerson.self,
        SocialAttendance.self,
        SessionStudentConfirmation.self
    ]

    /// The SwiftData schema for the iPhone app.
    static let schema = Schema(modelTypes)

    /// Builds the SwiftData container.
    ///
    private static func makeContainer() -> ModelContainer {
        do {
            let config = makeConfiguration()
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not open the CoachPlanner store: \(error)")
        }
    }

    private static func makeConfiguration() -> ModelConfiguration {
        // Preserve the exact store URL already used by the installed iPhone app.
        let legacyLocalConfiguration = ModelConfiguration(
            schema: schema,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return ModelConfiguration(
            schema: schema,
            url: legacyLocalConfiguration.url,
            cloudKitDatabase: .none
        )
    }
}
