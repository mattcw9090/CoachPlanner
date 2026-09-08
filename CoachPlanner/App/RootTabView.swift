import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selectedSection: AppSection = .sessions
    @State private var socialsWeekStart = SocialSessionListView.monday(of: .now)

    var body: some View {
        rootContent
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.willSave, object: modelContext)) { _ in
                if modelContext.hasChanges {
                    for model in modelContext.changedModelsArray {
                        if !SyncTimestamping.isApplyingRemoteChange,
                           let timestamped = model as? SyncTimestamped {
                            timestamped.updatedAt = .now
                        }
                    }
                }
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

            PlanningAutomationView()
                .tabItem {
                    Label("Automation", systemImage: "slider.horizontal.3")
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
        case .automation:
            PlanningAutomationView()
        }
    }
#endif
}

private enum AppSection: String, CaseIterable, Identifiable {
    case students
    case sessions
    case socials
    case settings
    case automation

    var id: Self { self }

    var title: String {
        switch self {
        case .students: return "Students"
        case .sessions: return "Sessions"
        case .socials: return "Socials"
        case .settings: return "Settings"
        case .automation: return "Automation"
        }
    }

    var systemImage: String {
        switch self {
        case .students: return "person.3.fill"
        case .sessions: return "calendar"
        case .socials: return "figure.badminton"
        case .settings: return "gearshape.fill"
        case .automation: return "slider.horizontal.3"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .students: return "1"
        case .sessions: return "2"
        case .socials: return "3"
        case .settings: return ","
        case .automation: return "5"
        }
    }
}

private struct AppSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppStorageKey.trsBookingContactPhone) private var trsBookingContactPhone = ""
    @State private var isContactPickerPresented = false
    @StateObject private var cloud = SupabaseCloud.shared
    @State private var cloudEmail = ""
    @State private var cloudPassword = ""

    private var phoneNumberBinding: Binding<String> {
        Binding(
            get: { AustralianPhoneNumber.groupedLocal(from: trsBookingContactPhone) },
            set: { trsBookingContactPhone = AustralianPhoneNumber.international(from: $0) }
        )
    }

    private var hasEnteredPhoneNumber: Bool {
        !AustralianPhoneNumber.localDigits(from: trsBookingContactPhone).isEmpty
    }

    private var isPhoneNumberValid: Bool {
        AustralianPhoneNumber.whatsappDigits(from: trsBookingContactPhone) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Text("+61")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        TextField("412 345 678", text: phoneNumberBinding)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)

                        Button {
                            isContactPickerPresented = true
                        } label: {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Choose TRS contact from Contacts")
                    }
                } header: {
                    Text("TRS Booking Contact")
                } footer: {
                    if hasEnteredPhoneNumber && !isPhoneNumberValid {
                        Text("Enter a complete 9-digit Australian phone number.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Used by the Sessions tab to prepare a WhatsApp request for the unbooked TRS courts in the displayed week.")
                    }
                }

                Section {
                    TextField("Supabase email", text: $cloudEmail)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)

                    SecureField("Supabase password", text: $cloudPassword)
                    .textContentType(.password)

                    HStack {
                        if cloud.isSignedIn {
                            Button(cloud.isSyncing ? "Syncing…" : "Sync cloud data") {
                                Task { await cloud.syncAll(in: modelContext) }
                            }
                            .disabled(cloud.isSyncing)

                            Button("Sign out") {
                                cloud.signOut()
                            }
                            .buttonStyle(.borderless)
                            .disabled(cloud.isSyncing)
                        } else {
                            Button("Sign in") {
                                Task {
                                    await cloud.signIn(email: cloudEmail, password: cloudPassword)
                                    cloudPassword = ""
                                }
                            }
                            .disabled(cloudEmail.isEmpty || cloudPassword.isEmpty)
                        }
                    }

                    if let result = cloud.lastSyncResult {
                        Label(result.summary, systemImage: result.needsAttention ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(result.needsAttention ? Color.orange : Color.green)
                    }

                    if let error = cloud.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Supabase Cloud")
                } footer: {
                    Text("Cloud sync runs only when you tap a sync action. Your password is used only to obtain a short-lived session token and is never stored; the token is kept in the device Keychain.")
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(AppStyle.background)
            .desktopContentWidth(720)
        }
        .background(
            PhoneContactPickerPresenter(
                isPresented: $isContactPickerPresented
            ) { phone in
                trsBookingContactPhone = AustralianPhoneNumber.international(from: phone)
            }
        )
    }
}

#Preview {
    RootTabView()
}
