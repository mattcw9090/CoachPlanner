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

    /// Opens New Socials on an in-memory sample roster. Normal launches ignore it and keep the iPhone store.
    static let sampleSocialSheetArgument = "-CoachPlannerSampleSocialSheet"

    static var isSampleSocialSheetLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains(sampleSocialSheetArgument)
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
            let container = try ModelContainer(for: schema, configurations: [config])
            if isSampleSocialSheetLaunch {
                seedSampleSocialRoster(in: container)
            }
            return container
        } catch {
            fatalError("Could not open the CoachPlanner store: \(error)")
        }
    }

    private static func makeConfiguration() -> ModelConfiguration {
        if isSampleSocialSheetLaunch {
            return ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
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

    private static func seedSampleSocialRoster(in container: ModelContainer) {
        let context = ModelContext(container)
        let studentNames = [
            "Alex Chen", "Priya Shah", "Jordan Lee", "Sam Patel",
            "Riley Nguyen", "Morgan Blake", "Taylor Brooks", "Jamie Ortiz"
        ]
        for name in studentNames {
            context.insert(Student(name: name, gender: "", contactPreference: .sms, contactDetail: ""))
        }
        let hidden = Student(name: "Casey Brooks", gender: "", contactPreference: .sms, contactDetail: "")
        hidden.isHidden = true
        context.insert(hidden)
        for name in ["Matt Chew", "Noah Grant", "Avery Kim"] {
            context.insert(Outsider(name: name, gender: "", contactPreference: .sms, contactDetail: ""))
        }
        do {
            try context.save()
        } catch {
            fatalError("Could not seed the sample social roster: \(error)")
        }
    }
}
