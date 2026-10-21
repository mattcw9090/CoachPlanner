import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var automaticSync = SupabaseAutoSync.shared
    @State private var socialsWeekStart = SocialSessionListView.monday(of: .now)
    @State private var section: Section = .students
    @State private var isConflictReviewPresented = false

    private enum Section: Hashable {
        case students, sessions, socials, settings
    }

    var body: some View {
        rootContent
            .onAppear {
                automaticSync.attach(to: modelContext, active: scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, newPhase in
                automaticSync.setActive(newPhase == .active)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let prompt = automaticSync.attentionPrompt {
                    attentionPrompt(prompt)
                }
            }
            .sheet(isPresented: $isConflictReviewPresented) {
                SyncConflictReviewView(cloud: SupabaseCloud.shared)
            }
    }

    private var rootContent: some View {
        TabView(selection: $section) {
            StudentListView()
                .tabItem {
                    Label("Students", systemImage: "person.3.fill")
                }
                .tag(Section.students)

            SessionListView()
                .tabItem {
                    Label("Sessions", systemImage: "calendar")
                }
                .tag(Section.sessions)

            SocialSessionListView(weekStart: $socialsWeekStart)
                .tabItem {
                    Label("Socials", systemImage: "figure.badminton")
                }
                .tag(Section.socials)

            AppSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(Section.settings)
        }
        .tint(.blue)
    }

    private func attentionPrompt(_ prompt: SyncAttentionPrompt) -> some View {
        Button {
            switch prompt {
            case .conflict:
                isConflictReviewPresented = true
            case .signIn, .uploadFailed, .saveFailed:
                section = .settings
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: prompt.systemImage)
                Text(prompt.title)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.gradient)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(prompt.title)
        .accessibilityHint(prompt == .conflict ? "Opens conflict review" : "Opens Settings")
    }
}

#Preview {
    RootTabView()
}
