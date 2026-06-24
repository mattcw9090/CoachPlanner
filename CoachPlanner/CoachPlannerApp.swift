import SwiftData
import SwiftUI

@main
struct CoachPlannerApp: App {
    var body: some Scene {
        WindowGroup {
            StudentListView()
        }
        .modelContainer(for: Student.self)
    }
}
