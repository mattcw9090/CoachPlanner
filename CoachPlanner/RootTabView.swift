import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            StudentListView()
                .tabItem {
                    Label("Students", systemImage: "person.3.fill")
                }

            SessionListView()
                .tabItem {
                    Label("Sessions", systemImage: "calendar")
                }
        }
    }
}

#Preview {
    RootTabView()
}
