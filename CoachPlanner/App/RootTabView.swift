import OSLog
import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selectedSection: AppSection = .sessions
    @State private var cloudRefreshID = UUID()
    @State private var awaitingInitialCloudImport: Bool?
    @State private var socialsWeekStart = SocialSessionListView.monday(of: .now)

    private static let syncLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.matthewchew.CoachPlanner",
        category: "SyncUI"
    )

    var body: some View {
        rootContent
            .onAppear {
                prepareInitialImportRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .coachPlannerCloudKitImportCompleted)) { _ in
                refreshAfterInitialImportIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.willSave, object: modelContext)) { _ in
                if modelContext.hasChanges {
                    for model in modelContext.changedModelsArray {
                        if !SyncTimestamping.isApplyingRemoteChange,
                           let timestamped = model as? SyncTimestamped {
                            timestamped.updatedAt = .now
                        }
                    }
                    awaitingInitialCloudImport = false
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
                .id("\(selectedSection.rawValue)-\(cloudRefreshID.uuidString)")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_000, minHeight: 700)
        .tint(.blue)
        .desktopReadableTypography()
#else
        TabView {
            StudentListView()
                .id("students-\(cloudRefreshID.uuidString)")
                .tabItem {
                    Label("Students", systemImage: "person.3.fill")
                }

            SessionListView()
                .id("sessions-\(cloudRefreshID.uuidString)")
                .tabItem {
                    Label("Sessions", systemImage: "calendar")
                }

            SocialSessionListView(weekStart: $socialsWeekStart)
                .id("socials-\(cloudRefreshID.uuidString)")
                .tabItem {
                    Label("Socials", systemImage: "figure.badminton")
                }

            AppSettingsView()
                .id("settings-\(cloudRefreshID.uuidString)")
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }

            PlanningAutomationView()
                .id("automation-\(cloudRefreshID.uuidString)")
                .tabItem {
                    Label("Automation", systemImage: "slider.horizontal.3")
                }
        }
        .tint(.blue)
#endif
    }

    private func prepareInitialImportRefresh() {
        guard awaitingInitialCloudImport == nil else { return }

        do {
            awaitingInitialCloudImport = try !hasStoredRecords(in: modelContext)
        } catch {
            awaitingInitialCloudImport = false
            Self.syncLogger.error("Could not check initial local data: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshAfterInitialImportIfNeeded() {
        guard awaitingInitialCloudImport == true else { return }
        guard !modelContext.hasChanges else {
            awaitingInitialCloudImport = false
            return
        }

        do {
            let importedContext = ModelContext(modelContext.container)
            importedContext.autosaveEnabled = false
            guard try hasStoredRecords(in: importedContext) else { return }

            // Only an initially empty store needs this first-import workaround.
            // Routine imports must not discard scroll positions, filters, or editors.
            awaitingInitialCloudImport = false
            cloudRefreshID = UUID()
            Self.syncLogger.debug("Refreshed views after the initial CloudKit restore")
        } catch {
            Self.syncLogger.error("Could not check imported data: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func hasStoredRecords(in context: ModelContext) throws -> Bool {
        for modelType in CoachPlannerApp.modelTypes {
            if try hasStoredRecords(of: modelType, in: context) {
                return true
            }
        }
        return false
    }

    private func hasStoredRecords<Model: PersistentModel>(of type: Model.Type, in context: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<Model>()
        descriptor.fetchLimit = 1
        return try !context.fetchIdentifiers(descriptor).isEmpty
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
                        Button(cloud.isSignedIn ? "Refresh cloud snapshot" : "Sign in and check cloud") {
                            Task {
                                if cloud.isSignedIn {
                                    await cloud.refreshSnapshot()
                                } else {
                                    await cloud.signIn(email: cloudEmail, password: cloudPassword)
                                    cloudPassword = ""
                                }
                            }
                        }
                        .disabled(cloud.isSyncing || (!cloud.isSignedIn && (cloudEmail.isEmpty || cloudPassword.isEmpty)))

                        if cloud.isSignedIn {
                            Button("Sign out") {
                                cloud.signOut()
                            }
                            .buttonStyle(.borderless)
                            .disabled(cloud.isSyncing)
                        }
                    }

                    if let snapshot = cloud.snapshot {
                        Label("Cloud snapshot: \(snapshot.summary)", systemImage: "checkmark.icloud")
                            .foregroundStyle(.green)
                        if let refreshedAt = cloud.lastSuccessfulRefreshAt {
                            Text("Last refreshed \(refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button(cloud.isSyncing ? "Syncing…" : "Sync cloud data") {
                            Task { await cloud.syncAll(in: modelContext) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(cloud.isSyncing)
                        if let result = cloud.lastSyncResult {
                            Label(result.summary, systemImage: result.needsAttention ? "exclamationmark.triangle" : "checkmark.circle")
                                .font(.footnote)
                                .foregroundStyle(result.needsAttention ? Color.orange : Color.green)
                        }
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
