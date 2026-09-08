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
        SocialAttendance.self
    ]

    /// The schema shared across the iOS and Mac Catalyst app.
    static let schema = Schema(modelTypes)

    /// Builds the SwiftData container.
    ///
    private static func makeContainer() -> ModelContainer {
        do {
            let config = try makeConfiguration()
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not open the CoachPlanner store: \(error)")
        }
    }

    private static func makeConfiguration() throws -> ModelConfiguration {
#if targetEnvironment(macCatalyst)
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let storeDirectory = applicationSupportURL.appendingPathComponent(
            PersistenceSettings.catalystStoreDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        let storeURL = storeDirectory.appendingPathComponent(
            PersistenceSettings.storeFileName,
            isDirectory: false
        )
#else
        // Preserve the exact store URL already used by the installed iPhone app.
        let legacyLocalConfiguration = ModelConfiguration(
            schema: schema,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        let storeURL = legacyLocalConfiguration.url
#endif

        return ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
    }
}

enum PersistenceSettings {
    static let catalystStoreDirectoryName = "CoachPlanner"
    static let storeFileName = "CoachPlanner.store"
}
