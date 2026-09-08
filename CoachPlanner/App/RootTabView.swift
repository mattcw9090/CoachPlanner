import OSLog
import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var coachingSessions: [CoachingSession]
    @State private var selectedSection: AppSection = .sessions
    @State private var cloudRefreshID = UUID()
    @State private var awaitingInitialCloudImport: Bool?
    @State private var socialsWeekStart = SocialSessionListView.monday(of: .now)
    @State private var didAttemptCloudKitRepair = false

    private static let syncLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.matthewchew.CoachPlanner",
        category: "SyncUI"
    )

    var body: some View {
        rootContent
            .onAppear {
                prepareInitialImportRefresh()
                repairDirectDraftRecordsIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    didAttemptCloudKitRepair = false
                    repairDirectDraftRecordsIfNeeded()
                }
            }
            .onChange(of: coachingSessions.count) { _, _ in
                repairDirectDraftRecordsIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .coachPlannerCloudKitImportCompleted)) { _ in
                refreshAfterInitialImportIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.willSave, object: modelContext)) { _ in
                if modelContext.hasChanges {
                    awaitingInitialCloudImport = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Repair draft sync") {
                        didAttemptCloudKitRepair = false
                        repairDirectDraftRecordsIfNeeded()
                    }
                    .help("Republish the seven locally inserted draft records through SwiftData")
                }
            }
    }

    private func repairDirectDraftRecordsIfNeeded() {
        guard !didAttemptCloudKitRepair else { return }
        guard !coachingSessions.isEmpty else { return }
        didAttemptCloudKitRepair = true
        let candidateCount = PlanningAutomation.directDraftRepairCandidateCount(sessions: coachingSessions)
        Self.syncLogger.notice("CloudKit draft repair candidates: \(candidateCount, privacy: .public) of \(coachingSessions.count, privacy: .public)")
        guard candidateCount == 6 else { return }
        do {
            _ = try PlanningAutomation.republishDirectDraftSessions(
                sessions: coachingSessions,
                modelContext: modelContext
            )
            Self.syncLogger.notice("Republished the affected draft records through SwiftData for CloudKit export")
        } catch {
            Self.syncLogger.error("CloudKit draft repair was not applied: \(error.localizedDescription, privacy: .public)")
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
    @AppStorage(AppStorageKey.trsBookingContactPhone) private var trsBookingContactPhone = ""
    @State private var isContactPickerPresented = false

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
