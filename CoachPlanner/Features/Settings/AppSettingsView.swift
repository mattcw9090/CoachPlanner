import SwiftData
import SwiftUI

struct AppSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppStorageKey.trsBookingContactPhone) private var trsBookingContactPhone = ""
    @StateObject private var cloud = SupabaseCloud.shared
    @State private var cloudEmail = ""
    @State private var cloudPassword = ""
    @State private var isContactPickerPresented = false
    @State private var isSigningIn = false
    @FocusState private var focusedCredential: CredentialField?

    private enum CredentialField: Hashable {
        case email
        case password
    }

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

    private var canSignIn: Bool {
        !cloudEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !cloudPassword.isEmpty &&
            !isSigningIn
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    bookingContactCard
                    cloudSyncCard
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(AppStyle.background.ignoresSafeArea())
            .navigationTitle("Settings")
        }
        .background(
            PhoneContactPickerPresenter(
                isPresented: $isContactPickerPresented
            ) { phone in
                trsBookingContactPhone = AustralianPhoneNumber.international(from: phone)
            }
        )
    }

    private var bookingContactCard: some View {
        SettingsCard(
            title: "TRS booking contact",
            systemImage: "phone.fill",
            tint: .blue
        ) {
            Text("Used when preparing WhatsApp requests for unbooked TRS courts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("+61")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)

                TextField("412 345 678", text: phoneNumberBinding)
                    .textFieldStyle(.plain)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .accessibilityLabel("TRS booking phone number")

                Button {
                    isContactPickerPresented = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.blue.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .accessibilityLabel("Choose TRS contact from Contacts")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(minHeight: 52)
            .background(inputBackground)

            if hasEnteredPhoneNumber && !isPhoneNumberValid {
                Label("Enter a complete 9-digit Australian phone number.", systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var cloudSyncCard: some View {
        SettingsCard(
            title: "Cloud sync",
            systemImage: "arrow.triangle.2.circlepath",
            tint: cloud.isSignedIn ? .green : .blue
        ) {
            if cloud.isSignedIn {
                connectedCloudControls
            } else {
                signedOutCloudControls
            }

            if let error = cloud.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectedCloudControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected to Supabase")
                        .font(.headline)
                    Text("This device is ready to exchange changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text("Connected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            }

            Button {
                Task { await cloud.syncAll(in: modelContext) }
            } label: {
                HStack(spacing: 8) {
                    if cloud.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(cloud.isSyncing ? "Syncing…" : "Sync cloud data")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(cloud.isSyncing)

            Text("Sync before starting on this device and again when you finish.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let result = cloud.lastSyncResult {
                Label(
                    result.summary,
                    systemImage: result.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(result.needsAttention ? Color.orange : Color.green)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("Sign out", role: .destructive) {
                cloud.signOut()
            }
            .disabled(cloud.isSyncing)
        }
    }

    private var signedOutCloudControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to connect this device to the shared CoachPlanner database.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                TextField("Email", text: $cloudEmail)
                    .textFieldStyle(.plain)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedCredential, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedCredential = .password }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(inputBackground)

            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                SecureField("Password", text: $cloudPassword)
                    .textFieldStyle(.plain)
                    .textContentType(.password)
                    .focused($focusedCredential, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(signIn)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(inputBackground)

            Button(action: signIn) {
                HStack(spacing: 8) {
                    if isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    Text(isSigningIn ? "Signing in…" : "Sign in")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSignIn)

            Label("Your password is never stored. The session token stays in this device's Keychain.", systemImage: "lock.shield.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(AppStyle.insetSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppStyle.separator.opacity(0.2), lineWidth: 0.5)
            )
    }

    private func signIn() {
        guard canSignIn else { return }
        focusedCredential = nil
        isSigningIn = true

        Task { @MainActor in
            await cloud.signIn(
                email: cloudEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                password: cloudPassword
            )
            cloudPassword = ""
            if cloud.isSignedIn {
                cloudEmail = ""
            }
            isSigningIn = false
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    private let content: Content

    init(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.12)))

                Text(title)
                    .font(.headline)
            }

            Divider()
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(AppStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppStyle.separator.opacity(0.15), lineWidth: 0.5)
        )
    }
}

#Preview {
    AppSettingsView()
        .modelContainer(for: CoachPlannerApp.modelTypes, inMemory: true)
}
