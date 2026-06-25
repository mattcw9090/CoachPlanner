import SwiftData
import SwiftUI

struct SessionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\CoachingSession.dayOfWeek),
            SortDescriptor(\CoachingSession.startTime)
        ]
    ) private var sessions: [CoachingSession]

    @State private var editor: SessionEditor?

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Sessions Yet", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("Add a session and choose which students will attend.")
                    } actions: {
                        Button("Add Session") {
                            editor = SessionEditor()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(sessions) { session in
                            Button {
                                editor = SessionEditor(session: session)
                            } label: {
                                SessionRow(session: session)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteSessions)
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = SessionEditor()
                    } label: {
                        Label("Add Session", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editor) { editor in
                SessionEditorView(editor: editor)
            }
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
    }
}

private struct SessionRow: View {
    let session: CoachingSession

    private var studentNames: String {
        let names = session.students
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.name)

        return names.isEmpty ? "No students selected" : names.joined(separator: ", ")
    }

    private var timeRange: String {
        let formatter = Date.FormatStyle.dateTime.hour().minute()
        return "\(session.startTime.formatted(formatter)) – \(session.endTime.formatted(formatter))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.title)
                    .font(.headline)

                Spacer()

                Text(session.weekday.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(timeRange)
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(session.venue)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(studentNames)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SessionListView()
        .modelContainer(for: [Student.self, CoachingSession.self], inMemory: true)
}
