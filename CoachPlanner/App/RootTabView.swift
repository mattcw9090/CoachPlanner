import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var automaticSync = SupabaseAutoSync.shared
    @State private var selectedSection: AppSection = .sessions
    @State private var socialsWeekStart = SocialSessionListView.monday(of: .now)

    var body: some View {
        rootContent
            .onAppear {
                automaticSync.attach(to: modelContext, active: scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, newPhase in
                automaticSync.setActive(newPhase == .active)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
            }
    }

    @ViewBuilder
    private var rootContent: some View {
#if targetEnvironment(macCatalyst)
        NavigationSplitView {
            List {
                ForEach(AppSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(section.shortcut, modifiers: .command)
                    .foregroundStyle(selectedSection == section ? Color.accentColor : Color.primary)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedSection == section ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("CoachPlanner")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            selectedSectionView
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_000, minHeight: 700)
        .tint(.blue)
        .desktopReadableTypography()
#else
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
#endif
    }

#if targetEnvironment(macCatalyst)
    @ViewBuilder
    private var selectedSectionView: some View {
        switch selectedSection {
        case .students:
            StudentListView()
        case .sessions:
            SessionListView()
        case .socials:
            SocialSessionListView(weekStart: $socialsWeekStart)
        case .settings:
            AppSettingsView()
        }
    }
#endif
}

private enum AppSection: String, CaseIterable, Identifiable {
    case students
    case sessions
    case socials
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .students: return "Students"
        case .sessions: return "Sessions"
        case .socials: return "Socials"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .students: return "person.3.fill"
        case .sessions: return "calendar"
        case .socials: return "figure.badminton"
        case .settings: return "gearshape.fill"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .students: return "1"
        case .sessions: return "2"
        case .socials: return "3"
        case .settings: return ","
        }
    }
}

#Preview {
    RootTabView()
}
