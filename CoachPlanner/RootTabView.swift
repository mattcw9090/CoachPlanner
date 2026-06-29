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

            SocialSessionListView()
                .tabItem {
                    Label("Socials", systemImage: "figure.badminton")
                }
        }
        .tint(.blue)
    }
}

#Preview {
    RootTabView()
}
