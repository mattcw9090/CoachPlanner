import SwiftData
import SwiftUI

private struct AttentionPromptHandlerKey: EnvironmentKey {
    static let defaultValue: (SyncAttentionPrompt) -> Void = { _ in }
}

extension EnvironmentValues {
    var attentionPromptHandler: (SyncAttentionPrompt) -> Void {
        get { self[AttentionPromptHandlerKey.self] }
        set { self[AttentionPromptHandlerKey.self] = newValue }
    }
}

/// Draws the attention prompt under the navigation bar, so it stays clear of Add, Share, and Move week.
struct AttentionPromptInset: ViewModifier {
    @StateObject private var automaticSync = SupabaseAutoSync.shared
    @Environment(\.attentionPromptHandler) private var handler

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if let prompt = automaticSync.attentionPrompt {
                promptButton(prompt)
            }
        }
    }

    private func promptButton(_ prompt: SyncAttentionPrompt) -> some View {
        Button {
            handler(prompt)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: prompt.systemImage)
                Text(prompt.title)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
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

extension View {
    func attentionPromptInset() -> some View {
        modifier(AttentionPromptInset())
    }
}

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var automaticSync = SupabaseAutoSync.shared
    @State private var section: Section = .students
    @State private var isConflictReviewPresented = false

    private enum Section: Hashable {
        case students, sessions, socials, settings
    }

    var body: some View {
        rootContent
            .environment(\.attentionPromptHandler) { prompt in
                switch prompt {
                case .conflict:
                    isConflictReviewPresented = true
                case .signIn, .uploadFailed, .saveFailed:
                    section = .settings
                }
            }
            .onAppear {
                automaticSync.attach(to: modelContext, active: scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, newPhase in
                automaticSync.setActive(newPhase == .active)
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

            SocialSessionListView()
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
}

#Preview {
    RootTabView()
}
