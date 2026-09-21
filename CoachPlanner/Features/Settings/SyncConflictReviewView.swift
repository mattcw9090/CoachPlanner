import SwiftUI

/// Displays only the comparisons already captured by sync. Presenting this
/// sheet does not fetch records, trigger sync, or resolve conflicting edits.
struct SyncConflictReviewView: View {
    @ObservedObject var cloud: SupabaseCloud
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SyncConflictReviewContent(
                conflicts: cloud.conflicts,
                lastCheckedAt: cloud.conflictDetailsLastCheckedAt
            )
            .navigationTitle("Sync conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .desktopSheetSize(width: 680, height: 600)
        .desktopReadableTypography()
    }
}

/// A pure presentation view also used by deterministic previews.
struct SyncConflictReviewContent: View {
    let conflicts: [SyncConflict]
    let lastCheckedAt: Date?
    @State private var expandedIDs: Set<String>

    init(conflicts: [SyncConflict], lastCheckedAt: Date?) {
        self.conflicts = conflicts
        self.lastCheckedAt = lastCheckedAt
        _expandedIDs = State(initialValue: Set(conflicts.prefix(1).map(\.id)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                reviewExplanation

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
            Label("Read-only comparison", systemImage: "eye")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)

            Text("These values were captured when sync detected different edits on this device and in the cloud. They may have changed since. Opening this review does not refresh or change either version.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
#endif
