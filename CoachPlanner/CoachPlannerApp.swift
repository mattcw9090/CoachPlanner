import CloudKit
import CoreData
import OSLog
import SwiftData
import SwiftUI

@main
struct CoachPlannerApp: App {
    let modelContainer: ModelContainer

    init() {
        PersistenceDiagnostics.startCloudKitLogging()

        let container = Self.makeContainer()
        CoachPlannerApp.modelContainer = container
        self.modelContainer = container
        PersistenceDiagnostics.logLocalRecordCounts(in: container)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
    }

    // Exposed so non-View code (e.g. backups) can reach the same container.
    static private(set) var modelContainer: ModelContainer!

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
        // Derive the URL from the previous local-only configuration, then add
        // CloudKit to that exact file. Existing iPhone records are opened in
        // place and become eligible for export instead of starting a new store.
        let legacyLocalConfiguration = ModelConfiguration(
            schema: schema,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        let config = ModelConfiguration(
            schema: schema,
            url: legacyLocalConfiguration.url,
            cloudKitDatabase: .private(PersistenceSettings.cloudKitContainerIdentifier)
        )
        let storeExists = FileManager.default.fileExists(atPath: config.url.path)

        PersistenceDiagnostics.logger.info(
            "Opening SwiftData store at \(config.url.path, privacy: .public); existing=\(storeExists, privacy: .public); CloudKit=\(PersistenceSettings.cloudKitContainerIdentifier, privacy: .public)"
        )

        do {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains(PersistenceSettings.schemaInitializationArgument) {
                try initializeCloudKitSchema(using: config)
            }
#endif
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            let nsError = error as NSError
            PersistenceDiagnostics.logger.fault(
                "Could not open the SwiftData/CloudKit store: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(nsError.localizedDescription, privacy: .public)"
            )
            fatalError("Could not open the CoachPlanner store: \(error)")
        }
    }

#if DEBUG
    private static func initializeCloudKitSchema(using configuration: ModelConfiguration) throws {
        PersistenceDiagnostics.logger.notice("Initializing the CloudKit development schema")

        try autoreleasepool {
            let description = NSPersistentStoreDescription(url: configuration.url)
            let options = NSPersistentCloudKitContainerOptions(
                containerIdentifier: PersistenceSettings.cloudKitContainerIdentifier
            )
            options.databaseScope = .private
            description.cloudKitContainerOptions = options
            description.shouldAddStoreAsynchronously = false

            guard let managedObjectModel = NSManagedObjectModel.makeManagedObjectModel(for: modelTypes) else {
                throw PersistenceSetupError.couldNotCreateManagedObjectModel
            }

            let container = NSPersistentCloudKitContainer(
                name: "CoachPlanner",
                managedObjectModel: managedObjectModel
            )
            container.persistentStoreDescriptions = [description]

            var loadError: Error?
            container.loadPersistentStores { _, error in
                loadError = error
            }
            if let loadError {
                throw loadError
            }

            defer {
                if let store = container.persistentStoreCoordinator.persistentStores.first {
                    do {
                        try container.persistentStoreCoordinator.remove(store)
                    } catch {
                        PersistenceDiagnostics.logger.error(
                            "Could not unload the schema-initialization store: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }

            try container.initializeCloudKitSchema()
            PersistenceDiagnostics.logger.notice("CloudKit development schema initialized")
        }
    }
#endif
}

enum PersistenceSettings {
    static let cloudKitContainerIdentifier = "iCloud.com.matthewchew.CoachPlanner"
    static let schemaInitializationArgument = "-initializeCloudKitSchema"
}

private enum PersistenceSetupError: LocalizedError {
    case couldNotCreateManagedObjectModel

    var errorDescription: String? {
        "SwiftData could not create the Core Data model used to initialize the CloudKit schema."
    }
}

private enum PersistenceDiagnostics {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.matthewchew.CoachPlanner",
        category: "Persistence"
    )

    private static var cloudKitEventObserver: NSObjectProtocol?

    static func startCloudKitLogging() {
        if cloudKitEventObserver == nil {
            cloudKitEventObserver = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else {
                    return
                }

                let eventType = String(describing: event.type)
                if event.endDate == nil {
                    logger.debug("CloudKit \(eventType, privacy: .public) started")
                } else if event.succeeded {
                    logger.info("CloudKit \(eventType, privacy: .public) completed")
                } else {
                    logger.error(
                        "CloudKit \(eventType, privacy: .public) failed: \(event.error?.localizedDescription ?? "Unknown error", privacy: .public)"
                    )
                }
            }
        }

    }

    static func logLocalRecordCounts(in container: ModelContainer) {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        do {
            let students = try context.fetchCount(FetchDescriptor<Student>())
            let hiddenWeeks = try context.fetchCount(FetchDescriptor<StudentHiddenWeek>())
            let outsiders = try context.fetchCount(FetchDescriptor<Outsider>())
            let sessions = try context.fetchCount(FetchDescriptor<CoachingSession>())
            let courts = try context.fetchCount(FetchDescriptor<CourtBooking>())
            let socials = try context.fetchCount(FetchDescriptor<SocialSession>())
            let hiddenPeople = try context.fetchCount(FetchDescriptor<SocialHiddenPerson>())
            let attendances = try context.fetchCount(FetchDescriptor<SocialAttendance>())

            logger.info(
                "Local records loaded: students=\(students, privacy: .public), hiddenWeeks=\(hiddenWeeks, privacy: .public), outsiders=\(outsiders, privacy: .public), sessions=\(sessions, privacy: .public), courts=\(courts, privacy: .public), socials=\(socials, privacy: .public), hiddenPeople=\(hiddenPeople, privacy: .public), attendances=\(attendances, privacy: .public)"
            )
        } catch {
            logger.error("Could not count local records: \(error.localizedDescription, privacy: .public)")
        }
    }

}
