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

            AppSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(.blue)
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
