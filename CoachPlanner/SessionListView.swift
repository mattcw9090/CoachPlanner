import SwiftData
import SwiftUI
import UIKit

struct SessionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\CoachingSession.dayOfWeek),
            SortDescriptor(\CoachingSession.startTime)
        ]
    ) private var sessions: [CoachingSession]
    @Query(
        sort: [
            SortDescriptor(\CourtBooking.dayOfWeek),
            SortDescriptor(\CourtBooking.startTime)
        ]
    ) private var courtBookings: [CourtBooking]

    @AppStorage("weekStartTimestamp") private var weekStartTimestamp: Double = 0

    @State private var editor: SessionEditor?
    @State private var courtBookingEditor: CourtBookingEditor?
    @State private var isWeekPickerPresented = false
    @State private var draftSelection: DraftSessionSelection?
    @State private var pendingDraftSelection: DraftSessionSelection?
    @State private var fileExport: FileExportItem?
    @State private var financeSendNotice: FinanceSendNotice?

    private let dayStartHour = 6
    private let dayEndHour = 23
    private let hourHeight: CGFloat = 64
    private let timeAxisWidth: CGFloat = 42
    private let dayHeaderHeight: CGFloat = 46
    private let calendarHorizontalPadding: CGFloat = 12
    private let gridLineOpacity: Double = 0.26
    private let activeGridLineOpacity: Double = 0.42

    private var visibleHours: Range<Int> { dayStartHour..<dayEndHour }
    private var totalGridHeight: CGFloat { CGFloat(visibleHours.count) * hourHeight }

    private var scheduleSummary: ScheduleSummary {
        var sessionsByDay = Dictionary(uniqueKeysWithValues: Weekday.allCases.map { ($0, [CoachingSession]()) })
        var courtBookingsByDay = Dictionary(uniqueKeysWithValues: Weekday.allCases.map { ($0, [CourtBooking]()) })
        var confirmedSessionCount = 0
        var totalSessionFees = 0.0

        for session in sessions {
            sessionsByDay[session.weekday, default: []].append(session)
            if session.statusValue == .confirmed {
                confirmedSessionCount += 1
            }
            totalSessionFees += session.sessionFee
        }

        for booking in courtBookings {
            courtBookingsByDay[booking.weekday, default: []].append(booking)
        }

        return ScheduleSummary(
            sessionsByDay: sessionsByDay,
            courtBookingsByDay: courtBookingsByDay,
            confirmedSessionCount: confirmedSessionCount,
            totalSessionFees: totalSessionFees
        )
    }

    private var weekStart: Date {
        if weekStartTimestamp == 0 {
            return Self.monday(of: .now)
        }
        return Date(timeIntervalSince1970: weekStartTimestamp)
    }

    private var weekEnd: Date {
        Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
    }

    private var weekRangeText: String {
        let formatter = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return "Week of \(weekStart.formatted(formatter)) – \(weekEnd.formatted(formatter))"
    }

    private func date(for day: Weekday) -> Date {
        Calendar.current.date(byAdding: .day, value: day.rawValue - 1, to: weekStart) ?? weekStart
    }

    private func dayOfMonth(for day: Weekday) -> Int {
        Calendar.current.component(.day, from: date(for: day))
    }

    private func isToday(_ day: Weekday) -> Bool {
        Calendar.current.isDateInToday(date(for: day))
    }

    private func minutesOfDay(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private func time(for totalMinutes: Int) -> Date {
        let clamped = min(max(totalMinutes, 0), 24 * 60 - 1)
        return Calendar.current.date(
            bySettingHour: clamped / 60,
            minute: clamped % 60,
            second: 0,
            of: .now
        ) ?? .now
    }

    private func snappedStartMinutes(for yPosition: CGFloat) -> Int {
        let rawMinutes = dayStartHour * 60 + Int((max(yPosition, 0) / hourHeight) * 60)
        return max(
            dayStartHour * 60,
            min((rawMinutes / 30) * 30, dayEndHour * 60 - 30)
        )
    }

    private func snappedEndMinutes(for yPosition: CGFloat) -> Int {
        let rawMinutes = dayStartHour * 60 + Int((max(yPosition, 0) / hourHeight) * 60)
        return max(
            dayStartHour * 60 + 30,
            min(((rawMinutes + 29) / 30) * 30, dayEndHour * 60)
        )
    }

    var body: some View {
        let summary = scheduleSummary

        NavigationStack {
            VStack(spacing: 0) {
                weekBanner
                    .padding(.horizontal, calendarHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                weekSummaryStrip(summary)
                    .padding(.horizontal, calendarHorizontalPadding)
                    .padding(.bottom, 10)

                dayHeaderRow
                    .padding(.horizontal, calendarHorizontalPadding)

                ScrollView(.vertical) {
                    grid(summary)
                        .frame(maxWidth: .infinity)
                    .padding(.horizontal, calendarHorizontalPadding)
                    .padding(.bottom, 28)
                }
            }
            .background(AppStyle.background)
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            editor = SessionEditor(weekStart: weekStart)
                        } label: {
                            Label("Session", systemImage: "person.2.fill")
                        }

                        Button {
                            courtBookingEditor = CourtBookingEditor()
                        } label: {
                            Label("Vacant Court", systemImage: "sportscourt.fill")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let url = prepareICSFile() {
                            fileExport = FileExportItem(url: url)
                        }
                    } label: {
                        Label("Export Calendar", systemImage: "calendar")
                    }
                    .disabled(sessions.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sendToFinanceTracker()
                    } label: {
                        Label("Send to Finance Tracker", systemImage: "dollarsign.circle")
                    }
                    .disabled(sessions.isEmpty)
                }

            }
            .sheet(item: $editor) { editor in
                SessionEditorView(editor: editor)
            }
            .sheet(item: $courtBookingEditor) { editor in
                CourtBookingEditorView(editor: editor)
            }
            .sheet(isPresented: $isWeekPickerPresented) {
                WeekStartPickerView(currentStart: weekStart) { newStart in
                    weekStartTimestamp = newStart.timeIntervalSince1970
                }
            }
            .sheet(item: $fileExport) { item in
                ICSShareSheet(url: item.url)
            }
            .alert(item: $financeSendNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func weekSummaryStrip(_ summary: ScheduleSummary) -> some View {
        HStack(spacing: 8) {
            MetricTile(
                title: "Sessions",
                value: "\(sessions.count)",
                systemImage: "calendar",
                tint: .blue
            )
            MetricTile(
                title: "Confirmed",
                value: "\(summary.confirmedSessionCount)",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
            MetricTile(
                title: "Fees",
                value: summary.totalSessionFees.formatted(.currency(code: AppStyle.currencyCode).precision(.fractionLength(0...2))),
                systemImage: "dollarsign.circle.fill",
                tint: .purple
            )
        }
    }

    private var weekBanner: some View {
        Button {
            isWeekPickerPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)

                Text(weekRangeText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.radius)
                    .fill(AppStyle.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppStyle.radius)
                    .stroke(AppStyle.separator.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeAxisWidth, height: dayHeaderHeight)
            ForEach(Weekday.allCases) { day in
                VStack(spacing: 2) {
                    Text(String(day.name.prefix(3)))
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(isToday(day) ? Color.accentColor : Color.secondary)
                    Text("\(dayOfMonth(for: day))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isToday(day) ? .white : .primary)
                        .frame(width: 28, height: 28)
                        .background {
                            if isToday(day) {
                                Circle().fill(Color.accentColor)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
                .frame(height: dayHeaderHeight)
            }
        }
        .padding(.bottom, 6)
        .background(AppStyle.background)
    }

    private func grid(_ summary: ScheduleSummary) -> some View {
        HStack(alignment: .top, spacing: 0) {
            timeAxis

            ForEach(Weekday.allCases) { day in
                dayColumn(for: day, summary: summary)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color(.separator).opacity(isDrafting(day) ? activeGridLineOpacity : gridLineOpacity))
                            .frame(width: 1)
                    }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppStyle.radius)
                .fill(AppStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.radius)
                .stroke(AppStyle.separator.opacity(0.34), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.radius))
        .overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                if let pendingDraftSelection {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.pendingDraftSelection = nil
                        }
                        .zIndex(4)

                    DraftTypePopover(
                        timeRange: draftTimeRangeText(for: pendingDraftSelection),
                        onSession: {
                            openSessionEditor(with: pendingDraftSelection)
                            self.pendingDraftSelection = nil
                        },
                        onCourtBooking: {
                            openCourtBookingEditor(with: pendingDraftSelection)
                            self.pendingDraftSelection = nil
                        },
                        onCancel: {
                            self.pendingDraftSelection = nil
                        }
                    )
                    .frame(width: DraftTypePopover.width)
                    .position(
                        x: draftPopoverX(for: pendingDraftSelection, gridWidth: proxy.size.width),
                        y: draftPopoverY(for: pendingDraftSelection)
                    )
                    .transition(.scale(scale: 0.92, anchor: .center).combined(with: .opacity))
                    .zIndex(5)
                }
            }
            .allowsHitTesting(pendingDraftSelection != nil)
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: pendingDraftSelection)
    }

    private var timeAxis: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear.frame(width: timeAxisWidth, height: totalGridHeight)
            ForEach(visibleHours, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
                    .offset(y: CGFloat(hour - dayStartHour) * hourHeight - 7)
            }
        }
        .frame(width: timeAxisWidth)
        .background(AppStyle.surface)
    }

    private func dayColumn(for day: Weekday, summary: ScheduleSummary) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(visibleHours, id: \.self) { _ in
                    Rectangle()
                        .fill(Color(.separator).opacity(isDrafting(day) ? activeGridLineOpacity : gridLineOpacity))
                        .frame(height: 0.75)
                    Color.clear.frame(height: hourHeight - 0.75)
                }
            }

            TimeSlotLongPressOverlay(
                day: day,
                onChanged: { day, startY, currentY in
                    draftSelection = selection(for: day, startY: startY, currentY: currentY)
                },
                onEnded: { day, startY, currentY in
                    let selection = selection(for: day, startY: startY, currentY: currentY)
                    draftSelection = nil
                    pendingDraftSelection = selection
                },
                onCancelled: {
                    draftSelection = nil
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: totalGridHeight)

            if let activeDraftSelection, activeDraftSelection.day == day {
                DraftSessionBlock()
                    .frame(height: height(for: activeDraftSelection))
                    .padding(.horizontal, 2)
                    .offset(y: yOffset(for: activeDraftSelection))
                    .allowsHitTesting(false)
            }

            ForEach(summary.sessions(for: day)) { session in
                SessionBlock(session: session)
                    .frame(height: blockHeight(for: session))
                    .padding(.horizontal, 2)
                    .offset(y: yOffset(for: session))
                    .onTapGesture {
                        editor = SessionEditor(session: session, weekStart: weekStart)
                    }
            }

            ForEach(summary.courtBookings(for: day)) { booking in
                CourtBookingBlock(booking: booking)
                    .frame(height: blockHeight(for: booking))
                    .padding(.horizontal, 2)
                    .offset(y: yOffset(for: booking))
                    .onTapGesture {
                        courtBookingEditor = CourtBookingEditor(booking: booking)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalGridHeight)
        .background(
            ZStack {
                AppStyle.surface
                if isDrafting(day) {
                    Color.accentColor.opacity(0.035)
                }
            }
        )
        .clipped()
    }

    private func isDrafting(_ day: Weekday) -> Bool {
        activeDraftSelection?.day == day
    }

    private var activeDraftSelection: DraftSessionSelection? {
        draftSelection ?? pendingDraftSelection
    }

    private func selection(for day: Weekday, startY: CGFloat, currentY: CGFloat) -> DraftSessionSelection {
        let lowerY = min(startY, currentY)
        let upperY = max(startY, currentY)
        let startMinutes = snappedStartMinutes(for: lowerY)
        let endMinutes = max(startMinutes + 30, snappedEndMinutes(for: upperY))

        return DraftSessionSelection(
            day: day,
            startMinutes: startMinutes,
            endMinutes: min(endMinutes, dayEndHour * 60)
        )
    }

    private func openSessionEditor(with selection: DraftSessionSelection) {
        editor = SessionEditor(
            preselectedDay: selection.day,
            preselectedStartTime: time(for: selection.startMinutes),
            preselectedEndTime: time(for: selection.endMinutes),
            weekStart: weekStart
        )
    }

    private func openCourtBookingEditor(with selection: DraftSessionSelection) {
        courtBookingEditor = CourtBookingEditor(
            preselectedDay: selection.day,
            preselectedStartTime: time(for: selection.startMinutes),
            preselectedEndTime: time(for: selection.endMinutes)
        )
    }

    private func draftPopoverX(for selection: DraftSessionSelection, gridWidth: CGFloat) -> CGFloat {
        let dayColumnWidth = max((gridWidth - timeAxisWidth) / CGFloat(Weekday.allCases.count), 1)
        let rawX = timeAxisWidth + (CGFloat(selection.day.rawValue - 1) * dayColumnWidth) + (dayColumnWidth / 2)
        let horizontalInset = (DraftTypePopover.width / 2) + 8
        return min(max(rawX, horizontalInset), max(horizontalInset, gridWidth - horizontalInset))
    }

    private func draftPopoverY(for selection: DraftSessionSelection) -> CGFloat {
        let selectionTop = yOffset(for: selection)
        let selectionHeight = height(for: selection)
        let preferredY = selectionTop - 52
        if preferredY > 78 {
            return preferredY
        }
        return selectionTop + selectionHeight + 58
    }

    private func draftTimeRangeText(for selection: DraftSessionSelection) -> String {
        "\(timeText(for: selection.startMinutes))-\(timeText(for: selection.endMinutes))"
    }

    private func timeText(for totalMinutes: Int) -> String {
        let hour = totalMinutes / 60
        let minute = totalMinutes % 60
        let period = hour < 12 ? "am" : "pm"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let minuteText = minute == 0 ? "" : ".\(String(format: "%02d", minute))"
        return "\(displayHour)\(minuteText)\(period)"
    }

    private func yOffset(for session: CoachingSession) -> CGFloat {
        let mins = minutesOfDay(session.startTime) - dayStartHour * 60
        return CGFloat(mins) / 60.0 * hourHeight
    }

    private func yOffset(for booking: CourtBooking) -> CGFloat {
        let mins = minutesOfDay(booking.startTime) - dayStartHour * 60
        return CGFloat(mins) / 60.0 * hourHeight
    }

    private func blockHeight(for session: CoachingSession) -> CGFloat {
        let duration = minutesOfDay(session.endTime) - minutesOfDay(session.startTime)
        return max(CGFloat(duration) / 60.0 * hourHeight - 5, 30)
    }

    private func blockHeight(for booking: CourtBooking) -> CGFloat {
        let duration = minutesOfDay(booking.endTime) - minutesOfDay(booking.startTime)
        return max(CGFloat(duration) / 60.0 * hourHeight - 5, 30)
    }

    private func yOffset(for selection: DraftSessionSelection) -> CGFloat {
        let mins = selection.startMinutes - dayStartHour * 60
        return CGFloat(mins) / 60.0 * hourHeight
    }

    private func height(for selection: DraftSessionSelection) -> CGFloat {
        let duration = selection.endMinutes - selection.startMinutes
        return max(CGFloat(duration) / 60.0 * hourHeight - 5, 30)
    }

    private func hourLabel(_ hour: Int) -> String {
        let cal = Calendar.current
        let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }

    static func monday(of date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? date
    }

    private func prepareICSFile() -> URL? {
        let content = generateICSContent()
        guard let data = content.data(using: .utf8) else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoachPlanner-Schedule.ics")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func sendToFinanceTracker() {
        let payloads = sessions.map { session in
            FinanceBridge.SessionPayload(
                sessionName: sessionName(for: session),
                dayOfWeek: session.weekday.name,
                sessionFee: session.sessionFee
            )
        }

        switch FinanceBridge.send(sessions: payloads, exportedAt: .now) {
        case let .success(count, _):
            financeSendNotice = FinanceSendNotice(
                title: "Sent to Finance Tracker",
                message: "\(count) \(count == 1 ? "session" : "sessions") shared with MyFinanceTracker. Open MyFinanceTracker to import them."
            )
        case let .failure(reason):
            financeSendNotice = FinanceSendNotice(
                title: "Couldn't Send",
                message: reason
            )
        }
    }

    private func sessionName(for session: CoachingSession) -> String {
        let studentList = session.students
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.name)
            .joined(separator: ", ")

        return studentList.isEmpty ? "\(session.venue) coaching" : studentList
    }

    private func generateICSContent() -> String {
        let calendar = Calendar.current

        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        localFormatter.timeZone = .current
        localFormatter.locale = Locale(identifier: "en_US_POSIX")

        let utcFormatter = DateFormatter()
        utcFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        utcFormatter.timeZone = TimeZone(identifier: "UTC")
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")

        let stamp = utcFormatter.string(from: .now)

        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//CoachPlanner//Sessions//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH"
        ]

        for session in sessions {
            guard let eventDate = calendar.date(
                byAdding: .day,
                value: session.dayOfWeek - 1,
                to: weekStart
            ) else { continue }

            let startComps = calendar.dateComponents([.hour, .minute], from: session.startTime)
            let endComps = calendar.dateComponents([.hour, .minute], from: session.endTime)
            let dateComps = calendar.dateComponents([.year, .month, .day], from: eventDate)

            var startBuild = DateComponents()
            startBuild.year = dateComps.year
            startBuild.month = dateComps.month
            startBuild.day = dateComps.day
            startBuild.hour = startComps.hour
            startBuild.minute = startComps.minute

            var endBuild = startBuild
            endBuild.hour = endComps.hour
            endBuild.minute = endComps.minute

            guard let startDate = calendar.date(from: startBuild),
                  let endDate = calendar.date(from: endBuild) else { continue }

            let dtStart = localFormatter.string(from: startDate)
            let dtEnd = localFormatter.string(from: endDate)
            let uid = "\(Int(session.createdAt.timeIntervalSince1970 * 1000))-coachplanner@local"

            let studentList = session.students
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map(\.name)
                .joined(separator: ", ")

            let trimmedCourt = session.courtNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let courtInfo = trimmedCourt.isEmpty ? "Court unbooked" : "Court \(trimmedCourt)"

            let summary = studentList.isEmpty
                ? "Coaching at \(session.venue)"
                : "Coaching: \(studentList)"

            var descriptionParts: [String] = []
            if !studentList.isEmpty {
                descriptionParts.append("Students: \(studentList)")
            }
            descriptionParts.append(courtInfo)
            descriptionParts.append("Status: \(session.statusValue.rawValue)")
            let description = descriptionParts.joined(separator: "\\n")

            lines += [
                "BEGIN:VEVENT",
                "UID:\(uid)",
                "DTSTAMP:\(stamp)",
                "DTSTART:\(dtStart)",
                "DTEND:\(dtEnd)",
                "RRULE:FREQ=WEEKLY",
                "SUMMARY:\(icsEscape(summary))",
                "LOCATION:\(icsEscape(session.venue))",
                "DESCRIPTION:\(icsEscape(description))",
                "STATUS:\(icsStatus(session.statusValue))",
                "END:VEVENT"
            ]
        }

        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    private func icsEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func icsStatus(_ status: SessionStatus) -> String {
        switch status {
        case .unscheduled, .pending: return "TENTATIVE"
        case .confirmed: return "CONFIRMED"
        }
    }
}

private struct FileExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct FinanceSendNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct ScheduleSummary {
    let sessionsByDay: [Weekday: [CoachingSession]]
    let courtBookingsByDay: [Weekday: [CourtBooking]]
    let confirmedSessionCount: Int
    let totalSessionFees: Double

    func sessions(for day: Weekday) -> [CoachingSession] {
        sessionsByDay[day] ?? []
    }

    func courtBookings(for day: Weekday) -> [CourtBooking] {
        courtBookingsByDay[day] ?? []
    }
}

private struct ICSShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct TimeSlotLongPressOverlay: UIViewRepresentable {
    let day: Weekday
    let onChanged: (Weekday, CGFloat, CGFloat) -> Void
    let onEnded: (Weekday, CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            day: day,
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        recognizer.minimumPressDuration = 0.35
        recognizer.allowableMovement = 12
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator

        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.day = day
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var day: Weekday
        var onChanged: (Weekday, CGFloat, CGFloat) -> Void
        var onEnded: (Weekday, CGFloat, CGFloat) -> Void
        var onCancelled: () -> Void
        private var startY: CGFloat?

        init(
            day: Weekday,
            onChanged: @escaping (Weekday, CGFloat, CGFloat) -> Void,
            onEnded: @escaping (Weekday, CGFloat, CGFloat) -> Void,
            onCancelled: @escaping () -> Void
        ) {
            self.day = day
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            let locationY = recognizer.location(in: recognizer.view).y

            switch recognizer.state {
            case .began:
                startY = locationY
                onChanged(day, locationY, locationY)
            case .changed:
                guard let startY else { return }
                onChanged(day, startY, locationY)
            case .ended:
                guard let startY else {
                    onCancelled()
                    return
                }
                onEnded(day, startY, locationY)
                self.startY = nil
            case .cancelled, .failed:
                startY = nil
                onCancelled()
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

private struct DraftSessionSelection: Equatable {
    let day: Weekday
    let startMinutes: Int
    let endMinutes: Int
}

private struct DraftSessionBlock: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.accentColor, lineWidth: 1.5)
            )
            .shadow(color: Color.accentColor.opacity(0.16), radius: 8, x: 0, y: 3)
    }
}

private struct DraftTypePopover: View {
    static let width: CGFloat = 226

    let timeRange: String
    let onSession: () -> Void
    let onCourtBooking: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add block")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(timeRange)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
            }

            HStack(spacing: 8) {
                DraftTypeButton(
                    title: "Session",
                    systemImage: "person.2.fill",
                    tint: .accentColor,
                    action: onSession
                )

                DraftTypeButton(
                    title: "Court",
                    systemImage: "sportscourt.fill",
                    tint: .gray,
                    action: onCourtBooking
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppStyle.separator.opacity(0.18), lineWidth: 0.75)
        )
    }
}

private struct DraftTypeButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(tint.opacity(0.14)))

                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(.secondarySystemGroupedBackground).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(tint.opacity(0.18), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SessionBlock: View {
    let session: CoachingSession

    private var color: Color {
        session.statusValue.color
    }

    private var studentNames: String {
        session.students
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.name)
            .joined(separator: ", ")
    }

    private var courtNumber: String {
        session.courtNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCourtBooked: Bool {
        !courtNumber.isEmpty
    }

    private var sessionMetadata: String {
        var parts: [String] = []

        if !courtNumber.isEmpty {
            parts.append("Court \(courtNumber)")
        }

        return parts.joined(separator: " · ")
    }

    private var backgroundOpacity: Double {
        isCourtBooked ? 0.14 : 0.28
    }

    private var strokeOpacity: Double {
        isCourtBooked ? 0.36 : 0.68
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(studentNames.isEmpty ? "No students" : studentNames)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            Text(session.venue)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if !sessionMetadata.isEmpty {
                Text(sessionMetadata)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(backgroundOpacity))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(color)
                .frame(width: isCourtBooked ? 3 : 4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(strokeOpacity), lineWidth: isCourtBooked ? 0.75 : 1.1)
        )
        .shadow(color: isCourtBooked ? .clear : color.opacity(0.14), radius: 5, x: 0, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct CourtBookingBlock: View {
    let booking: CourtBooking

    private var courtNumber: String {
        booking.courtNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(booking.venue)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            Text("Court \(courtNumber)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.16))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.gray)
                .frame(width: 4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct CourtBookingEditor: Identifiable {
    let id = UUID()
    let booking: CourtBooking?
    let preselectedDay: Weekday?
    let preselectedStartTime: Date?
    let preselectedEndTime: Date?

    init(
        booking: CourtBooking? = nil,
        preselectedDay: Weekday? = nil,
        preselectedStartTime: Date? = nil,
        preselectedEndTime: Date? = nil
    ) {
        self.booking = booking
        self.preselectedDay = preselectedDay
        self.preselectedStartTime = preselectedStartTime
        self.preselectedEndTime = preselectedEndTime
    }
}

private struct CourtBookingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var existingSessions: [CoachingSession]
    @Query private var existingBookings: [CourtBooking]

    let editor: CourtBookingEditor

    @State private var dayOfWeek: Weekday
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var venue: Venue
    @State private var courtNumber: String

    init(editor: CourtBookingEditor) {
        self.editor = editor
        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: .now) ?? .now
        let defaultEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now

        _dayOfWeek = State(initialValue: editor.booking?.weekday ?? editor.preselectedDay ?? .monday)
        _startTime = State(initialValue: editor.booking?.startTime ?? editor.preselectedStartTime ?? defaultStart)
        _endTime = State(initialValue: editor.booking?.endTime ?? editor.preselectedEndTime ?? defaultEnd)
        _venue = State(initialValue: editor.booking?.venueValue ?? .pbaMalaga)
        _courtNumber = State(initialValue: editor.booking?.courtNumber ?? "")
    }

    private var isEditing: Bool {
        editor.booking != nil
    }

    private var trimmedCourtNumber: String {
        courtNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isTimeRangeValid: Bool {
        minutes(of: endTime) > minutes(of: startTime)
    }

    private var overlappingSession: CoachingSession? {
        let newStart = minutes(of: startTime)
        let newEnd = minutes(of: endTime)

        return existingSessions.first { session in
            session.dayOfWeek == dayOfWeek.rawValue &&
                newStart < minutes(of: session.endTime) &&
                newEnd > minutes(of: session.startTime)
        }
    }

    private var overlappingBooking: CourtBooking? {
        let editingID = editor.booking?.persistentModelID
        let newStart = minutes(of: startTime)
        let newEnd = minutes(of: endTime)

        return existingBookings.first { booking in
            booking.persistentModelID != editingID &&
                booking.dayOfWeek == dayOfWeek.rawValue &&
                newStart < minutes(of: booking.endTime) &&
                newEnd > minutes(of: booking.startTime)
        }
    }

    private var canSave: Bool {
        isTimeRangeValid &&
            !trimmedCourtNumber.isEmpty &&
            overlappingSession == nil &&
            overlappingBooking == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Venue", selection: $venue) {
                        ForEach(Venue.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }

                    TextField("Court number", text: $courtNumber)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Court")
                } footer: {
                    if trimmedCourtNumber.isEmpty {
                        Text("Court number is required.")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Day of Week", selection: $dayOfWeek) {
                        ForEach(Weekday.allCases) { day in
                            Text(day.name).tag(day)
                        }
                    }

                    LabeledContent("Start Time") {
                        HalfHourTimePicker(selection: $startTime)
                    }

                    LabeledContent("End Time") {
                        HalfHourTimePicker(selection: $endTime)
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    if !isTimeRangeValid {
                        Text("End time must be after start time.")
                            .foregroundStyle(.red)
                    } else if let overlap = overlappingSession {
                        Text("Overlaps with session at \(overlap.venue), \(timeRangeText(start: overlap.startTime, end: overlap.endTime)).")
                            .foregroundStyle(.red)
                    } else if let overlap = overlappingBooking {
                        Text("Overlaps with Court \(overlap.courtNumber) at \(overlap.venue), \(timeRangeText(start: overlap.startTime, end: overlap.endTime)).")
                            .foregroundStyle(.red)
                    }
                }

                if isEditing {
                    Section {
                        Button("Delete Court Booking", role: .destructive) {
                            deleteBooking()
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Court Booking" : "New Court Booking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func minutes(of date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private func timeRangeText(start: Date, end: Date) -> String {
        let formatter = Date.FormatStyle.dateTime.hour().minute()
        return "\(start.formatted(formatter))-\(end.formatted(formatter))"
    }

    private func save() {
        if let booking = editor.booking {
            booking.dayOfWeek = dayOfWeek.rawValue
            booking.startTime = startTime
            booking.endTime = endTime
            booking.venue = venue.rawValue
            booking.courtNumber = trimmedCourtNumber
        } else {
            let booking = CourtBooking(
                dayOfWeek: dayOfWeek,
                startTime: startTime,
                endTime: endTime,
                venue: venue,
                courtNumber: trimmedCourtNumber
            )
            modelContext.insert(booking)
        }

        dismiss()
    }

    private func deleteBooking() {
        guard let booking = editor.booking else { return }
        modelContext.delete(booking)
        dismiss()
    }
}

private struct WeekStartPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let currentStart: Date
    let onSave: (Date) -> Void

    @State private var selectedDate: Date

    init(currentStart: Date, onSave: @escaping (Date) -> Void) {
        self.currentStart = currentStart
        self.onSave = onSave
        _selectedDate = State(initialValue: currentStart)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MondayCalendarPicker(selection: $selectedDate)
                        .padding(.vertical, 8)
                } footer: {
                    Text("Week of \(selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())).")
                }

                Section {
                    Button("Use current week") {
                        selectedDate = SessionListView.monday(of: .now)
                    }
                }
            }
            .navigationTitle("Set Week Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(selectedDate)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct MondayCalendarPicker: View {
    @Binding var selection: Date
    @State private var visibleMonth: Date

    init(selection: Binding<Date>) {
        self._selection = selection
        self._visibleMonth = State(initialValue: selection.wrappedValue)
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal
    }

    private var firstDayOfMonth: Date {
        let comps = calendar.dateComponents([.year, .month], from: visibleMonth)
        return calendar.date(from: comps) ?? visibleMonth
    }

    private var daysInMonth: Range<Int> {
        calendar.range(of: .day, in: .month, for: visibleMonth) ?? 1..<32
    }

    private var leadingEmptyDays: Int {
        let weekday = calendar.component(.weekday, from: firstDayOfMonth)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    stepMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)

                Spacer()

                Button {
                    stepMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<leadingEmptyDays, id: \.self) { _ in
                    Color.clear.frame(height: 36)
                }
                ForEach(daysInMonth, id: \.self) { day in
                    let date = calendar.date(byAdding: .day, value: day - 1, to: firstDayOfMonth) ?? firstDayOfMonth
                    let isMonday = calendar.component(.weekday, from: date) == 2
                    let isSelected = calendar.isDate(date, inSameDayAs: selection)

                    DayCell(day: day, isMonday: isMonday, isSelected: isSelected) {
                        selection = date
                    }
                }
            }
        }
    }

    private func stepMonth(_ delta: Int) {
        if let new = calendar.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = new
        }
    }
}

private struct DayCell: View {
    let day: Int
    let isMonday: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text("\(day)")
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(textColor)
                .background {
                    if isSelected {
                        Circle().fill(Color.accentColor)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!isMonday)
    }

    private var textColor: Color {
        if !isMonday { return .secondary.opacity(0.4) }
        if isSelected { return .white }
        return .primary
    }
}

#Preview {
    SessionListView()
        .modelContainer(for: [Student.self, CoachingSession.self, CourtBooking.self], inMemory: true)
}
