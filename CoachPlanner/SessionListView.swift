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
    @Query(
        sort: [
            SortDescriptor(\SocialSession.weekStart),
            SortDescriptor(\SocialSession.dayOfWeek),
            SortDescriptor(\SocialSession.startTime)
        ]
    ) private var socialSessions: [SocialSession]

    @AppStorage("weekStartTimestamp") private var weekStartTimestamp: Double = 0

    @State private var editor: SessionEditor?
    @State private var courtBookingEditor: CourtBookingEditor?
    @State private var draftSelection: DraftSessionSelection?
    @State private var pendingDraftSelection: DraftSessionSelection?
    @State private var fileExport: FileExportItem?
    @State private var financeSendNotice: FinanceSendNotice?
    @State private var selectedCourtBooking: CourtBooking?
    @State private var isResetConfirmationPresented = false
    @State private var isSwapModeEnabled = false
    @State private var selectedSwapSession: CoachingSession?
    @State private var swapNotice: SessionSwapNotice?

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

    private var sessionsForWeek: [CoachingSession] {
        sessions.filter { belongsToVisibleWeek($0.weekStart) }
    }

    private var courtBookingsForWeek: [CourtBooking] {
        courtBookings.filter { belongsToVisibleWeek($0.weekStart) }
    }

    private var scheduleSummary: ScheduleSummary {
        var sessionsByDay = Dictionary(uniqueKeysWithValues: Weekday.allCases.map { ($0, [CoachingSession]()) })
        var courtBookingsByDay = Dictionary(uniqueKeysWithValues: Weekday.allCases.map { ($0, [CourtBooking]()) })
        var socialSessionsByDay = Dictionary(uniqueKeysWithValues: Weekday.allCases.map { ($0, [SocialSession]()) })
        var confirmedSessionCount = 0
        var totalSessionFees = 0.0

        for session in sessionsForWeek {
            sessionsByDay[session.weekday, default: []].append(session)
            if session.statusValue == .confirmed {
                confirmedSessionCount += 1
            }
            totalSessionFees += session.sessionFee
        }

        for booking in courtBookingsForWeek {
            courtBookingsByDay[booking.weekday, default: []].append(booking)
        }

        for social in socialSessions where Calendar.current.isDate(social.weekStart, inSameDayAs: weekStart) {
            socialSessionsByDay[social.weekday, default: []].append(social)
        }

        return ScheduleSummary(
            sessionsByDay: sessionsByDay,
            courtBookingsByDay: courtBookingsByDay,
            socialSessionsByDay: socialSessionsByDay,
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

    private func moveWeek(by offset: Int) {
        let nextWeek = Calendar.current.date(byAdding: .day, value: offset * 7, to: weekStart) ?? weekStart
        setWeekStart(nextWeek)
    }

    private func setWeekStart(_ date: Date) {
        pendingDraftSelection = nil
        draftSelection = nil
        selectedCourtBooking = nil
        selectedSwapSession = nil
        weekStartTimestamp = Self.monday(of: date).timeIntervalSince1970
    }

    private func belongsToVisibleWeek(_ recordWeekStart: Date?) -> Bool {
        guard let recordWeekStart else { return false }
        return Calendar.current.isDate(Self.monday(of: recordWeekStart), inSameDayAs: weekStart)
    }

    private func assignVisibleWeekToUnscopedRecordsIfNeeded() {
        let normalizedWeekStart = Self.monday(of: weekStart)
        for session in sessions where session.weekStart == nil {
            session.weekStart = normalizedWeekStart
        }
        for booking in courtBookings where booking.weekStart == nil {
            booking.weekStart = normalizedWeekStart
        }
    }

    private func handleWeekSwipe(_ value: DragGesture.Value) {
        guard pendingDraftSelection == nil,
              draftSelection == nil,
              selectedCourtBooking == nil else {
            return
        }

        let horizontal = value.translation.width
        let vertical = value.translation.height
        guard abs(horizontal) > 72, abs(horizontal) > abs(vertical) * 1.6 else {
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            moveWeek(by: horizontal < 0 ? 1 : -1)
        }
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
                weekSummaryStrip(summary)
                    .padding(.horizontal, calendarHorizontalPadding)
                    .padding(.top, 8)
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
                    Button {
                        if let url = prepareICSFile() {
                            fileExport = FileExportItem(url: url)
                        }
                    } label: {
                        Label("Export Calendar", systemImage: "calendar")
                    }
                    .disabled(sessionsForWeek.isEmpty && courtBookingsForWeek.isEmpty && summary.socialSessionsByDay.values.allSatisfy(\.isEmpty))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sendToFinanceTracker()
                    } label: {
                        Label("Send to Finance Tracker", systemImage: "dollarsign.circle")
                    }
                    .disabled(sessionsForWeek.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        toggleSwapMode()
                    } label: {
                        Label(isSwapModeEnabled ? "Cancel Swap" : "Swap Sessions", systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(sessionsForWeek.count < 2)
                    .tint(isSwapModeEnabled ? .orange : nil)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        isResetConfirmationPresented = true
                    } label: {
                        Label("Reset Sessions", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(sessionsForWeek.isEmpty)
                }

            }
            .confirmationDialog(
                "Reset all sessions?",
                isPresented: $isResetConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Reset Sessions", role: .destructive) {
                    resetSessions()
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This keeps every session and its students, but changes statuses to Unscheduled and clears booked court numbers.")
            }
            .sheet(item: $editor) { editor in
                SessionEditorView(editor: editor)
            }
            .sheet(item: $courtBookingEditor) { editor in
                CourtBookingEditorView(editor: editor)
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
            .alert(item: $swapNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .onAppear {
                assignVisibleWeekToUnscopedRecordsIfNeeded()
            }
        }
    }

    private func weekSummaryStrip(_ summary: ScheduleSummary) -> some View {
        HStack(spacing: 8) {
            MetricTile(
                title: "Sessions",
                value: "\(sessionsForWeek.count)",
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
        .contentShape(Rectangle())
        .simultaneousGesture(weekSwipeGesture)
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
                if pendingDraftSelection != nil || selectedCourtBooking != nil {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            pendingDraftSelection = nil
                            selectedCourtBooking = nil
                        }
                        .zIndex(4)
                }

                if let pendingDraftSelection {
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

                if let selectedCourtBooking {
                    VacantCourtPopover(
                        title: "Vacant court",
                        detail: vacantCourtDetail(for: selectedCourtBooking),
                        canAddSession: canTakeSession(from: selectedCourtBooking),
                        onSession: {
                            openSessionEditor(from: selectedCourtBooking)
                        },
                        onEdit: {
                            courtBookingEditor = CourtBookingEditor(weekStart: weekStart, booking: selectedCourtBooking)
                            self.selectedCourtBooking = nil
                        },
                        onCancel: {
                            self.selectedCourtBooking = nil
                        }
                    )
                    .frame(width: VacantCourtPopover.width)
                    .position(
                        x: courtBookingPopoverX(for: selectedCourtBooking, gridWidth: proxy.size.width),
                        y: courtBookingPopoverY(for: selectedCourtBooking)
                    )
                    .transition(.scale(scale: 0.92, anchor: .center).combined(with: .opacity))
                    .zIndex(5)
                }
            }
            .allowsHitTesting(pendingDraftSelection != nil || selectedCourtBooking != nil)
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: pendingDraftSelection)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: selectedCourtBooking?.persistentModelID)
        .contentShape(Rectangle())
        .simultaneousGesture(weekSwipeGesture)
    }

    private var weekSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 44)
            .onEnded { value in
                handleWeekSwipe(value)
            }
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
                SessionBlock(
                    session: session,
                    isSwapModeEnabled: isSwapModeEnabled,
                    isSwapEligible: canSwap(session),
                    isSwapSelected: selectedSwapSession?.persistentModelID == session.persistentModelID
                )
                    .frame(height: blockHeight(for: session))
                    .padding(.horizontal, 2)
                    .offset(y: yOffset(for: session))
                    .onTapGesture {
                        handleSessionTap(session)
                    }
            }

            ForEach(summary.courtBookings(for: day)) { booking in
                CourtBookingBlock(booking: booking)
                    .frame(height: blockHeight(for: booking))
                    .padding(.horizontal, 2)
                    .offset(y: yOffset(for: booking))
                    .onTapGesture {
                        guard !isSwapModeEnabled else { return }
                        pendingDraftSelection = nil
                        selectedCourtBooking = booking
                    }
            }

            ForEach(summary.socialSessions(for: day)) { social in
                SocialSessionBlock(session: social)
                    .frame(height: blockHeight(for: social))
                    .padding(.horizontal, 2)
                    .offset(y: yOffset(for: social))
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

    private func handleSessionTap(_ session: CoachingSession) {
        guard isSwapModeEnabled else {
            editor = SessionEditor(session: session, weekStart: weekStart)
            return
        }

        guard canSwap(session) else {
            swapNotice = SessionSwapNotice(
                title: "Can't Swap Session",
                message: "Only Unscheduled or Pending sessions can be swapped."
            )
            return
        }

        if selectedSwapSession?.persistentModelID == session.persistentModelID {
            selectedSwapSession = nil
            return
        }

        guard let firstSession = selectedSwapSession else {
            selectedSwapSession = session
            return
        }

        swapSessions(firstSession, session)
    }

    private func toggleSwapMode() {
        isSwapModeEnabled.toggle()
        selectedSwapSession = nil
    }

    private func swapSessions(_ firstSession: CoachingSession, _ secondSession: CoachingSession) {
        guard canSwap(firstSession), canSwap(secondSession) else {
            swapNotice = SessionSwapNotice(
                title: "Can't Swap Sessions",
                message: "Only Unscheduled or Pending sessions can be swapped."
            )
            selectedSwapSession = nil
            return
        }

        let firstDuration = durationMinutes(for: firstSession)
        let secondDuration = durationMinutes(for: secondSession)

        guard firstDuration == secondDuration else {
            swapNotice = SessionSwapNotice(
                title: "Can't Swap Sessions",
                message: "Only sessions with the same duration can be swapped. This is \(durationText(firstDuration)) and \(durationText(secondDuration))."
            )
            selectedSwapSession = nil
            return
        }

        let firstStudents = firstSession.students
        let firstFee = firstSession.sessionFee

        firstSession.students = secondSession.students
        firstSession.sessionFee = secondSession.sessionFee

        secondSession.students = firstStudents
        secondSession.sessionFee = firstFee

        selectedSwapSession = nil
        isSwapModeEnabled = false
    }

    private func canSwap(_ session: CoachingSession) -> Bool {
        session.statusValue == .unscheduled || session.statusValue == .pending
    }

    private func openCourtBookingEditor(with selection: DraftSessionSelection) {
        courtBookingEditor = CourtBookingEditor(
            weekStart: weekStart,
            preselectedDay: selection.day,
            preselectedStartTime: time(for: selection.startMinutes),
            preselectedEndTime: time(for: selection.endMinutes)
        )
    }

    private func openSessionEditor(from booking: CourtBooking) {
        guard canTakeSession(from: booking),
              let venue = Venue(rawValue: booking.venue),
              let endTime = Calendar.current.date(byAdding: .minute, value: suggestedSessionDurationMinutes(for: booking), to: booking.startTime) else {
            return
        }

        editor = SessionEditor(
            preselectedDay: booking.weekday,
            preselectedStartTime: booking.startTime,
            preselectedEndTime: endTime,
            preselectedVenue: venue,
            preselectedCourtNumber: booking.courtNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            consumedCourtBooking: booking,
            weekStart: weekStart
        )
        selectedCourtBooking = nil
    }

    private func canTakeSession(from booking: CourtBooking) -> Bool {
        durationMinutes(for: booking) >= 30
    }

    private func suggestedSessionDurationMinutes(for booking: CourtBooking) -> Int {
        min(durationMinutes(for: booking), 60)
    }

    private func durationMinutes(for booking: CourtBooking) -> Int {
        minutesOfDay(booking.endTime) - minutesOfDay(booking.startTime)
    }

    private func durationMinutes(for session: CoachingSession) -> Int {
        minutesOfDay(session.endTime) - minutesOfDay(session.startTime)
    }

    private func durationText(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return hours == 0 ? "\(remainingMinutes)m" : "\(hours)h \(remainingMinutes)m"
    }

    private func draftPopoverX(for selection: DraftSessionSelection, gridWidth: CGFloat) -> CGFloat {
        let dayColumnWidth = max((gridWidth - timeAxisWidth) / CGFloat(Weekday.allCases.count), 1)
        let rawX = timeAxisWidth + (CGFloat(selection.day.rawValue - 1) * dayColumnWidth) + (dayColumnWidth / 2)
        let horizontalInset = (DraftTypePopover.width / 2) + 8
        return min(max(rawX, horizontalInset), max(horizontalInset, gridWidth - horizontalInset))
    }

    private func courtBookingPopoverX(for booking: CourtBooking, gridWidth: CGFloat) -> CGFloat {
        let dayColumnWidth = max((gridWidth - timeAxisWidth) / CGFloat(Weekday.allCases.count), 1)
        let rawX = timeAxisWidth + (CGFloat(booking.dayOfWeek - 1) * dayColumnWidth) + (dayColumnWidth / 2)
        let horizontalInset = (VacantCourtPopover.width / 2) + 8
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

    private func courtBookingPopoverY(for booking: CourtBooking) -> CGFloat {
        let bookingTop = yOffset(for: booking)
        let bookingHeight = blockHeight(for: booking)
        let preferredY = bookingTop - 52
        if preferredY > 78 {
            return preferredY
        }
        return bookingTop + bookingHeight + 58
    }

    private func draftTimeRangeText(for selection: DraftSessionSelection) -> String {
        "\(timeText(for: selection.startMinutes))-\(timeText(for: selection.endMinutes))"
    }

    private func vacantCourtDetail(for booking: CourtBooking) -> String {
        "Court \(booking.courtNumber) · \(timeText(for: minutesOfDay(booking.startTime)))-\(timeText(for: minutesOfDay(booking.endTime)))"
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

    private func yOffset(for social: SocialSession) -> CGFloat {
        let mins = minutesOfDay(social.startTime) - dayStartHour * 60
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

    private func blockHeight(for social: SocialSession) -> CGFloat {
        let duration = minutesOfDay(social.endTime) - minutesOfDay(social.startTime)
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
        let payloads = sessionsForWeek.map { session in
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

    private func resetSessions() {
        for session in sessionsForWeek {
            session.status = SessionStatus.unscheduled.rawValue
            session.courtNumber = ""
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

        let utcFormatter = DateFormatter()
        utcFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        utcFormatter.timeZone = TimeZone(identifier: "UTC")
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")

        let stamp = utcFormatter.string(from: .now)

        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//CoachPlanner//Sessions//EN",
            "CALSCALE:GREGORIAN"
        ]

        for session in sessionsForWeek {
            guard let eventDates = eventDates(
                dayOfWeek: session.dayOfWeek,
                startTime: session.startTime,
                endTime: session.endTime,
                calendar: calendar
            ) else { continue }

            let dtStart = utcFormatter.string(from: eventDates.start)
            let dtEnd = utcFormatter.string(from: eventDates.end)
            let uid = [
                Int(session.createdAt.timeIntervalSince1970 * 1000),
                session.dayOfWeek,
                minutesOfDay(session.startTime),
                minutesOfDay(session.endTime)
            ]
                .map(String.init)
                .joined(separator: "-") + "-coachplanner@local"
            let status = session.statusValue

            let studentList = session.students
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map(\.name)
                .joined(separator: ", ")

            let trimmedCourt = session.courtNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCourtBooked = !trimmedCourt.isEmpty
            let courtInfo = trimmedCourt.isEmpty ? "Court unbooked" : "Court \(trimmedCourt)"
            let location = trimmedCourt.isEmpty ? session.venue : "\(session.venue), Court \(trimmedCourt)"

            let baseSummary = studentList.isEmpty
                ? "Unassigned Session"
                : studentList
            let summary = calendarTitle(
                base: baseSummary,
                status: status,
                isCourtBooked: isCourtBooked
            )

            var descriptionParts: [String] = [
                "CoachPlanner session",
                "Status: \(status.rawValue)",
                "Venue: \(session.venue)",
                courtInfo,
                "Day: \(session.weekday.name)",
                "Time: \(timeRangeText(start: session.startTime, end: session.endTime))",
                "Session fee: \(session.sessionFee.formatted(.currency(code: AppStyle.currencyCode).precision(.fractionLength(0...2))))"
            ]
            if !studentList.isEmpty {
                descriptionParts.append("Students: \(studentList)")
            } else {
                descriptionParts.append("Students: None assigned")
            }
            let description = descriptionParts.joined(separator: "\n")

            lines += [
                "BEGIN:VEVENT",
                "UID:\(uid)",
                "DTSTAMP:\(stamp)",
                "DTSTART:\(dtStart)",
                "DTEND:\(dtEnd)",
                "SUMMARY:\(icsEscape(summary))",
                "DESCRIPTION:\(icsEscape(description))",
                "LOCATION:\(icsEscape(location))",
                "END:VEVENT"
            ]
        }

        for booking in courtBookingsForWeek {
            guard let eventDates = eventDates(
                dayOfWeek: booking.dayOfWeek,
                startTime: booking.startTime,
                endTime: booking.endTime,
                calendar: calendar
            ) else { continue }

            let trimmedCourt = booking.courtNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let courtLabel = trimmedCourt.isEmpty ? "Court" : "Court \(trimmedCourt)"
            let location = trimmedCourt.isEmpty ? booking.venue : "\(booking.venue), \(courtLabel)"
            let summary = "COURT BOOKING"
            let uid = [
                "court",
                String(Int(booking.createdAt.timeIntervalSince1970 * 1000)),
                String(booking.dayOfWeek),
                String(minutesOfDay(booking.startTime)),
                String(minutesOfDay(booking.endTime))
            ]
                .joined(separator: "-") + "-coachplanner@local"
            let description = [
                "CoachPlanner vacant court booking",
                "Venue: \(booking.venue)",
                courtLabel,
                "Day: \(booking.weekday.name)",
                "Time: \(timeRangeText(start: booking.startTime, end: booking.endTime))"
            ].joined(separator: "\n")

            lines += [
                "BEGIN:VEVENT",
                "UID:\(uid)",
                "DTSTAMP:\(stamp)",
                "DTSTART:\(utcFormatter.string(from: eventDates.start))",
                "DTEND:\(utcFormatter.string(from: eventDates.end))",
                "SUMMARY:\(icsEscape(summary))",
                "DESCRIPTION:\(icsEscape(description))",
                "LOCATION:\(icsEscape(location))",
                "END:VEVENT"
            ]
        }

        lines.append("END:VCALENDAR")
        return lines.flatMap(foldedICSLines).joined(separator: "\r\n") + "\r\n"
    }

    private func eventDates(
        dayOfWeek: Int,
        startTime: Date,
        endTime: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        guard let eventDate = calendar.date(
            byAdding: .day,
            value: dayOfWeek - 1,
            to: weekStart
        ) else { return nil }

        let startComps = calendar.dateComponents([.hour, .minute], from: startTime)
        let endComps = calendar.dateComponents([.hour, .minute], from: endTime)
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
              let endDate = calendar.date(from: endBuild) else { return nil }

        return (startDate, endDate)
    }

    private func calendarTitle(
        base: String,
        status: SessionStatus,
        isCourtBooked: Bool
    ) -> String {
        var title = base
        if !isCourtBooked {
            title += " (UNBOOKED)"
        }
        if status == .pending || status == .unscheduled {
            title += "?"
        }
        return title
    }

    private func timeRangeText(start: Date, end: Date) -> String {
        let formatter = Date.FormatStyle.dateTime.hour().minute()
        return "\(start.formatted(formatter))-\(end.formatted(formatter))"
    }

    private func icsEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func foldedICSLines(_ line: String) -> [String] {
        let maxBytes = 75
        var folded: [String] = []
        var current = ""
        var currentBytes = 0

        for character in line {
            let characterBytes = String(character).utf8.count
            if currentBytes + characterBytes > maxBytes, !current.isEmpty {
                folded.append(current)
                current = " "
                currentBytes = 1
            }

            current.append(character)
            currentBytes += characterBytes
        }

        folded.append(current)
        return folded
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

private struct SessionSwapNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct ScheduleSummary {
    let sessionsByDay: [Weekday: [CoachingSession]]
    let courtBookingsByDay: [Weekday: [CourtBooking]]
    let socialSessionsByDay: [Weekday: [SocialSession]]
    let confirmedSessionCount: Int
    let totalSessionFees: Double

    func sessions(for day: Weekday) -> [CoachingSession] {
        sessionsByDay[day] ?? []
    }

    func courtBookings(for day: Weekday) -> [CourtBooking] {
        courtBookingsByDay[day] ?? []
    }

    func socialSessions(for day: Weekday) -> [SocialSession] {
        socialSessionsByDay[day] ?? []
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

private struct VacantCourtPopover: View {
    static let width: CGFloat = 226

    let title: String
    let detail: String
    let canAddSession: Bool
    let onSession: () -> Void
    let onEdit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
                    isEnabled: canAddSession,
                    action: onSession
                )

                DraftTypeButton(
                    title: "Edit",
                    systemImage: "pencil",
                    tint: .gray,
                    action: onEdit
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
    var isEnabled: Bool = true
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
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct SessionBlock: View {
    let session: CoachingSession
    var isSwapModeEnabled = false
    var isSwapEligible = true
    var isSwapSelected = false

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
        if isSwapSelected { return 0.95 }
        return isCourtBooked ? 0.36 : 0.68
    }

    private var strokeWidth: CGFloat {
        isSwapSelected ? 2.4 : (isCourtBooked ? 0.75 : 1.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isSwapSelected {
                Text("Swap from")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if isSwapModeEnabled && isSwapEligible {
                Text("Tap to swap")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(1)
            } else if isSwapModeEnabled {
                Text("Locked")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

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
                .stroke((isSwapSelected ? Color.orange : color).opacity(strokeOpacity), lineWidth: strokeWidth)
        )
        .shadow(color: isSwapSelected ? Color.orange.opacity(0.28) : (isCourtBooked ? .clear : color.opacity(0.14)), radius: 5, x: 0, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(isSwapModeEnabled && !isSwapEligible ? 0.48 : 1)
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

private struct SocialSessionBlock: View {
    let session: SocialSession

    private var courtSummary: String {
        guard session.areCourtsBooked else { return "" }
        let courts = session.courtNumbersList
        guard !courts.isEmpty else { return "Courts booked" }
        let label = courts.count == 1 ? "Court" : "Courts"
        return "\(label) \(courts.joined(separator: ", "))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            Text(session.venue)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if !courtSummary.isEmpty {
                Text(courtSummary)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.purple)
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
                .fill(Color.purple.opacity(0.16))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.purple)
                .frame(width: 4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.purple.opacity(0.48), lineWidth: 1)
        )
        .shadow(color: Color.purple.opacity(0.12), radius: 5, x: 0, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct CourtBookingEditor: Identifiable {
    let id = UUID()
    let weekStart: Date
    let booking: CourtBooking?
    let preselectedDay: Weekday?
    let preselectedStartTime: Date?
    let preselectedEndTime: Date?

    init(
        weekStart: Date,
        booking: CourtBooking? = nil,
        preselectedDay: Weekday? = nil,
        preselectedStartTime: Date? = nil,
        preselectedEndTime: Date? = nil
    ) {
        self.weekStart = SessionListView.monday(of: booking?.weekStart ?? weekStart)
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
            belongsToEditorWeek(session.weekStart) &&
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
                belongsToEditorWeek(booking.weekStart) &&
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

    private func belongsToEditorWeek(_ recordWeekStart: Date?) -> Bool {
        guard let recordWeekStart else { return true }
        return Calendar.current.isDate(SessionListView.monday(of: recordWeekStart), inSameDayAs: editor.weekStart)
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
            booking.weekStart = editor.weekStart
            booking.dayOfWeek = dayOfWeek.rawValue
            booking.startTime = startTime
            booking.endTime = endTime
            booking.venue = venue.rawValue
            booking.courtNumber = trimmedCourtNumber
        } else {
            let booking = CourtBooking(
                weekStart: editor.weekStart,
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

#Preview {
    SessionListView()
        .modelContainer(for: [Student.self, Outsider.self, CoachingSession.self, CourtBooking.self, SocialSession.self, SocialAttendance.self], inMemory: true)
}
