import SwiftUI

struct RootTabView: View {
    @State private var selectedSection: AppSection = .sessions

    var body: some View {
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
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            selectedSectionView
                .id(selectedSection)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_000, minHeight: 700)
        .tint(.blue)
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

            SocialSessionListView()
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
            SocialSessionListView()
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
