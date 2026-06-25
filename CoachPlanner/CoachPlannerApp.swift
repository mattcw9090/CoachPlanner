import SwiftData
import SwiftUI

@main
struct CoachPlannerApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(for: [Student.self, CoachingSession.self])
    }
}
