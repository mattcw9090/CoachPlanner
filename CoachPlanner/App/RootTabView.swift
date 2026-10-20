import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var automaticSync = SupabaseAutoSync.shared
    @State private var socialsWeekStart = SocialSessionListView.monday(of: .now)

    var body: some View {
        rootContent
            .onAppear {
                automaticSync.attach(to: modelContext, active: scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, newPhase in
                automaticSync.setActive(newPhase == .active)
            }
            // Leave the native tab bar's bottom safe area entirely to TabView.
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: automaticSync.needsAttention ? "exclamationmark.icloud" : "icloud")
                    Text(automaticSync.status)
                }
                .font(.caption)
                .foregroundStyle(automaticSync.needsAttention ? Color.orange : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .allowsHitTesting(false)
            }
    }

    private var rootContent: some View {
        TabView {
            StudentListView()
                .tabItem {
                    Label("Students", systemImage: "person.3.fill")
                }

            SessionListView()
                .tabItem {
                    Label("Sessions", systemImage: "calendar")
                }

            SocialSessionListView(weekStart: $socialsWeekStart)
                .tabItem {
                    Label("Socials", systemImage: "figure.badminton")
                }

            AppSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(.blue)
    }
}

#Preview {
    RootTabView()
}
