import SwiftData
import SwiftUI

/// Displays only the comparisons already captured by sync. Presenting this
/// sheet does not fetch or change records. A separate explicit confirmation is
/// required before a selected record is sent to the resolution service.
struct SyncConflictReviewView: View {
    @ObservedObject var cloud: SupabaseCloud
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var requestedResolution: SyncConflictResolutionRequest?
    @State private var isConfirmationPresented = false
    @State private var localResolvingID: String?
    @State private var feedback: SyncConflictReviewFeedback?

    private var resolvingID: String? { localResolvingID ?? cloud.resolvingConflictID }
    private var isResolving: Bool { resolvingID != nil }
    private var isBusy: Bool { cloud.isSyncing || isResolving }

    var body: some View {
        NavigationStack {
            SyncConflictReviewContent(
                conflicts: cloud.conflicts,
                lastCheckedAt: cloud.conflictDetailsLastCheckedAt,
                isBusy: isBusy,
                resolvingConflictID: resolvingID,
                feedback: feedback,
                onChoose: { conflict, choice in
                    guard !isBusy else { return }
                    requestedResolution = SyncConflictResolutionRequest(conflict: conflict, choice: choice)
                    isConfirmationPresented = true
                }
            )
            .navigationTitle("Sync conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isResolving)
                }
            }
        }
        .interactiveDismissDisabled(isResolving)
        .alert(
            requestedResolution?.confirmationTitle ?? "Resolve conflict?",
            isPresented: $isConfirmationPresented,
            presenting: requestedResolution
        ) { request in
            Button(request.actionLabel, role: request.keepsDeletion ? .destructive : nil) {
                applyResolution(request)
            }
            .disabled(isBusy)
            Button("Cancel", role: .cancel) { requestedResolution = nil }
        } message: { request in
            Text(request.explanation)
        }
        .desktopSheetSize(width: 680, height: 600)
        .desktopReadableTypography()
    }

    private func applyResolution(_ request: SyncConflictResolutionRequest) {
        requestedResolution = nil
        guard !isBusy else {
            feedback = SyncConflictReviewFeedback(message: "Sync is running. Wait for it to finish, then choose a version again.", isError: true)
            return
        }
        localResolvingID = request.conflict.id
        feedback = nil
        Task { @MainActor in
            defer { localResolvingID = nil }
            do {
                let message = try await cloud.resolveConflict(request.conflict, choice: request.choice, in: modelContext)
                feedback = SyncConflictReviewFeedback(message: message, isError: false)
            } catch {
                feedback = SyncConflictReviewFeedback(message: error.localizedDescription, isError: true)
            }
        }
    }
}

struct SyncConflictReviewFeedback {
    let message: String
    let isError: Bool
}

private struct SyncConflictResolutionRequest {
    let conflict: SyncConflict
    let choice: SyncConflictChoice

    var keepsDeletion: Bool {
        if case .device = choice { return conflict.localUpdatedAt == nil }
        return false
    }

    var actionLabel: String {
        switch choice {
        case .device: return conflict.localUpdatedAt == nil ? "Keep deletion" : "Use this device"
        case .cloud: return conflict.localUpdatedAt == nil ? "Restore cloud copy" : "Use cloud"
        }
    }

    var confirmationTitle: String { "\(actionLabel)?" }

    var explanation: String {
        let record = "\(conflict.entityName): \(conflict.title)\n\n"
        if conflict.localUpdatedAt == nil {
            switch choice {
            case .device:
                return record + "The entire cloud record will be marked as deleted and its relationships removed. Other devices will remove it when they sync. This choice keeps the deletion on this device."
            case .cloud:
                return record + "The full reviewed cloud record and its relationships will be restored on this device. All values are restored together; individual fields are not merged."
            }
        }
        switch choice {
        case .device:
            return record + "This device's saved version will replace the entire cloud record and its relationships. The conflicting cloud values will be replaced. Individual fields are not merged."
        case .cloud:
            return record + "The reviewed cloud version will replace this device's entire record and its relationships. The conflicting local values will be replaced. Individual fields are not merged."
        }
    }
}

/// A pure presentation view also used by deterministic previews.
struct SyncConflictReviewContent: View {
    let conflicts: [SyncConflict]
    let lastCheckedAt: Date?
    let isBusy: Bool
    let resolvingConflictID: String?
    let feedback: SyncConflictReviewFeedback?
    let onChoose: ((SyncConflict, SyncConflictChoice) -> Void)?
    @State private var expandedIDs: Set<String>

    init(
        conflicts: [SyncConflict], lastCheckedAt: Date?, isBusy: Bool = false,
        resolvingConflictID: String? = nil, feedback: SyncConflictReviewFeedback? = nil,
        onChoose: ((SyncConflict, SyncConflictChoice) -> Void)? = nil
    ) {
        self.conflicts = conflicts
        self.lastCheckedAt = lastCheckedAt
        self.isBusy = isBusy
        self.resolvingConflictID = resolvingConflictID
        self.feedback = feedback
        self.onChoose = onChoose
        _expandedIDs = State(initialValue: Set(conflicts.prefix(1).map(\.id)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                reviewExplanation

                if let feedback {
                    Label(feedback.message, systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(feedback.isError ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: AppStyle.radius).fill(AppStyle.surface))
                }

                if conflicts.isEmpty {
                    ContentUnavailableView {
                        Label("No conflict details available", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Use Sync cloud data in Settings to check all records. Comparisons are kept only while the app is running.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    Text("\(conflicts.count) conflicting \(conflicts.count == 1 ? "record" : "records")")
                        .font(.headline)

                    ForEach(conflicts) { conflict in
                        conflictCard(conflict)
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .background(AppStyle.background.ignoresSafeArea())
    }

    private var reviewExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(onChoose == nil ? "Read-only comparison" : "Review before choosing", systemImage: "eye")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)

            Text("These values were captured when sync detected different edits on this device and in the cloud. They may have changed since. Opening this review does not refresh or change either version.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if onChoose != nil {
                Text("Choose a version for one record, then confirm. Each choice applies the entire record and its relationships. Individual fields are not merged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastCheckedAt {
                Text("Last full check: \(Self.timestamp(lastCheckedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A full check has not completed in this app session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: AppStyle.radius).fill(AppStyle.surface))
    }

    private func conflictCard(_ conflict: SyncConflict) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedIDs.contains(conflict.id) },
            set: { expanded in
                if expanded { expandedIDs.insert(conflict.id) }
                else { expandedIDs.remove(conflict.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 16) {
                Text(conflict.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    timestampRow("Comparison captured", date: conflict.detectedAt)
                    timestampRow("This device changed", date: conflict.localUpdatedAt)
                    timestampRow("Cloud changed", date: conflict.cloudUpdatedAt)
                }

                Divider()

                if conflict.differences.isEmpty {
                    Text("No field comparison was captured for this record.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(conflict.differences) { difference in
                        SyncConflictFieldView(difference: difference)
                    }
                }

                if onChoose != nil {
                    resolutionControls(conflict)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Record ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(conflict.recordID.uuidString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(conflict.entityName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(conflict.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(conflict.differences.count) differing \(conflict.differences.count == 1 ? "field" : "fields")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .tint(.blue)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: AppStyle.radius).fill(AppStyle.surface))
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.radius)
                .stroke(AppStyle.separator.opacity(0.16), lineWidth: 0.5)
        }
    }

    private func timestampRow(_ label: String, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(date.map(Self.timestamp) ?? "Not available")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func resolutionControls(_ conflict: SyncConflict) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if resolvingConflictID == conflict.id {
                ProgressView("Applying selected version…")
                    .font(.footnote)
            } else if isBusy {
                Text("Choices are available after the current sync finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                onChoose?(conflict, .device)
            } label: {
                Label(conflict.localUpdatedAt == nil ? "Keep deletion" : "Use this device",
                      systemImage: conflict.localUpdatedAt == nil ? "trash" : "internaldrive")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .tint(conflict.localUpdatedAt == nil ? .red : .blue)

            Button {
                onChoose?(conflict, .cloud)
            } label: {
                Label(conflict.localUpdatedAt == nil ? "Restore cloud copy" : "Use cloud", systemImage: "icloud")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
        }
        .disabled(isBusy)
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

private struct SyncConflictFieldView: View {
    let difference: SyncConflictDifference
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(difference.label)
                .font(.subheadline.weight(.semibold))

            if horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    deviceValue
                    cloudValue
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    deviceValue
                    cloudValue
                }
            }
        }
    }

    private var deviceValue: some View {
        valueCard(label: "This device", value: difference.localValue, tint: .blue)
    }

    private var cloudValue: some View {
        valueCard(label: "Cloud", value: difference.cloudValue, tint: .green)
    }

    private func valueCard(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value.isEmpty ? "Not set" : value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }
}

#Preview("No conflict details") {
    NavigationStack {
        SyncConflictReviewContent(conflicts: [], lastCheckedAt: nil)
            .navigationTitle("Sync conflicts")
    }
}

#if DEBUG
enum SyncConflictPreviewData {
    static let capturedAt = Date(timeIntervalSince1970: 1_790_000_000)
    static let conflicts = [
        SyncConflict(
            id: "coaching_sessions:00000000-0000-0000-0000-000000000001",
            table: "coaching_sessions",
            recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            entityName: "Coaching session",
            title: "Monday, 21 September · 5:00 PM–6:00 PM",
            detectedAt: capturedAt,
            localUpdatedAt: capturedAt.addingTimeInterval(-90),
            cloudUpdatedAt: capturedAt.addingTimeInterval(-45),
            reason: "This device and the cloud both changed this session after its last successful sync.",
            differences: [
                SyncConflictDifference(id: "venue", label: "Venue", localValue: "Apex", cloudValue: "TRS"),
                SyncConflictDifference(id: "status", label: "Status", localValue: "Confirmed", cloudValue: "Pending"),
                SyncConflictDifference(id: "students", label: "Students", localValue: "Preview Student A", cloudValue: "Preview Student A\nPreview Student B")
            ]
        ),
        SyncConflict(
            id: "students:00000000-0000-0000-0000-000000000002",
            table: "students",
            recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            entityName: "Student",
            title: "Preview Student C",
            detectedAt: capturedAt,
            localUpdatedAt: capturedAt.addingTimeInterval(-180),
            cloudUpdatedAt: capturedAt.addingTimeInterval(-60),
            reason: "This device and the cloud contain different saved edits.",
            differences: [
                SyncConflictDifference(id: "sessions", label: "Sessions per week", localValue: "2", cloudValue: "1")
            ]
        )
    ]
}

#Preview("Captured conflicts") {
    NavigationStack {
        SyncConflictReviewContent(
            conflicts: SyncConflictPreviewData.conflicts,
            lastCheckedAt: SyncConflictPreviewData.capturedAt
        )
        .navigationTitle("Sync conflicts")
    }
}

#Preview("Resolution choices") {
    NavigationStack {
        SyncConflictReviewContent(
            conflicts: SyncConflictPreviewData.conflicts,
            lastCheckedAt: SyncConflictPreviewData.capturedAt,
            onChoose: { _, _ in }
        )
        .navigationTitle("Sync conflicts")
    }
}
#endif
