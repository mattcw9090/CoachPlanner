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
    @State private var socialSessionEditor: SocialSessionEditor?
    @State private var draftSelection: DraftSessionSelection?
    @State private var pendingDraftSelection: DraftSessionSelection?
    @State private var fileExport: FileExportItem?
    @State private var financeSendNotice: FinanceSendNotice?
    @State private var selectedCourtBooking: CourtBooking?
    @State private var isResetConfirmationPresented = false
    @State private var bulkSelectionAction: BulkSessionAction?
    @State private var bulkSessionSelection: Set<PersistentIdentifier> = []
    @State private var isMassCourtBookingSheetPresented = false
    @State private var isMassStatusSheetPresented = false
    @State private var weekDragTranslation: CGFloat = 0
    @State private var weekDragAxis: WeekDragAxis?
    @State private var isWeekCommitInProgress = false
    @State private var isWeekVerticalScrollLocked = false
    @State private var sessionDrag: SessionDragState?
    @State private var gridDayColumnWidth: CGFloat = 1

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

    private var socialSessionsForWeek: [SocialSession] {
        socialSessions.filter {
            Calendar.current.isDate(Self.monday(of: $0.weekStart), inSameDayAs: Self.monday(of: weekStart))
        }
    }

    private var unbookedSessionsForWeek: [CoachingSession] {
        sessionsForWeek.filter(isCourtUnbooked)
    }

    private var isBulkSelectionModeEnabled: Bool {
        bulkSelectionAction != nil
    }

    private var eligibleBulkSessions: [CoachingSession] {
        switch bulkSelectionAction {
        case .bookCourts:
            return unbookedSessionsForWeek
        case .setStatus:
            return sessionsForWeek
        case nil:
            return []
        }
    }

    private var selectedBulkSessions: [CoachingSession] {
        eligibleBulkSessions.filter {
            bulkSessionSelection.contains($0.persistentModelID)
        }
    }

    private var areAllEligibleBulkSessionsSelected: Bool {
        !eligibleBulkSessions.isEmpty &&
            selectedBulkSessions.count == eligibleBulkSessions.count
    }

    private var scheduleSummary: ScheduleSummary {
        scheduleSummary(for: weekStart)
    }

    private func scheduleSummary(for targetWeekStart: Date) -> ScheduleSummary {
        var sessionsByDay = Dictionary(uniqueKeysWithValues: Weekday.allCases.map { ($0, [CoachingSession]()) })
        var courtBookingsByDay = Dictionary(uniqueKeysWithValues: Weekday.allCases.map { ($0, [CourtBooking]()) })
        var socialSessionsByDay = Dictionary(uniqueKeysWithValues: Weekday.allCases.map { ($0, [SocialSession]()) })
        var confirmedSessionCount = 0
        var totalSessionFees = 0.0

        for session in sessions where belongs(session.weekStart, to: targetWeekStart) {
            sessionsByDay[session.weekday, default: []].append(session)
            if session.statusValue == .confirmed {
                confirmedSessionCount += 1
            }
            totalSessionFees += session.sessionFee
        }

        for booking in courtBookings where belongs(booking.weekStart, to: targetWeekStart) {
            courtBookingsByDay[booking.weekday, default: []].append(booking)
        }

        for social in socialSessions where Calendar.current.isDate(Self.monday(of: social.weekStart), inSameDayAs: Self.monday(of: targetWeekStart)) {
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

    private var previousWeekStart: Date {
        Self.monday(of: Calendar.current.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart)
    }

    private var nextWeekStart: Date {
        Self.monday(of: Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart)
    }

    private func setWeekStart(_ date: Date) {
        pendingDraftSelection = nil
        draftSelection = nil
        selectedCourtBooking = nil
        cancelBulkSelection()
        weekStartTimestamp = Self.monday(of: date).timeIntervalSince1970
    }

    private func belongs(_ recordWeekStart: Date?, to targetWeekStart: Date) -> Bool {
        guard let recordWeekStart else { return false }
        return Calendar.current.isDate(Self.monday(of: recordWeekStart), inSameDayAs: Self.monday(of: targetWeekStart))
    }

    private func belongsToVisibleWeek(_ recordWeekStart: Date?) -> Bool {
        belongs(recordWeekStart, to: weekStart)
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

    private var canBeginWeekDrag: Bool {
        pendingDraftSelection == nil &&
        draftSelection == nil &&
        selectedCourtBooking == nil &&
        sessionDrag == nil &&
        !isBulkSelectionModeEnabled &&
        !isWeekCommitInProgress
    }

    private func resolveWeekDragAxis(for value: DragGesture.Value) -> WeekDragAxis? {
        let horizontal = value.translation.width
        let vertical = value.translation.height
        let horizontalMagnitude = abs(horizontal)
        let verticalMagnitude = abs(vertical)

        guard max(horizontalMagnitude, verticalMagnitude) > 12 else {
            return nil
        }

        // Bias ambiguous diagonal movement toward vertical scrolling. A week
        // swipe should only take over once the horizontal intent is clear.
        if horizontalMagnitude > 20,
           horizontalMagnitude > verticalMagnitude * 1.35 {
            return .horizontal
        }

        if verticalMagnitude > 12 {
            return .vertical
        }

        return nil
    }

    private func rubberBandedWeekOffset(_ offset: CGFloat, pageWidth: CGFloat) -> CGFloat {
        let limit = max(pageWidth, 1)
        let magnitude = abs(offset)
        guard magnitude > limit else {
            return offset
        }

        let overflow = magnitude - limit
        let resisted = limit + overflow * 0.22
        return offset < 0 ? -resisted : resisted
    }

    private func handleWeekDragChanged(_ value: DragGesture.Value, pageWidth: CGFloat) {
        guard canBeginWeekDrag else {
            return
        }

        if weekDragAxis == nil {
            weekDragAxis = resolveWeekDragAxis(for: value)
        }

        guard weekDragAxis == .horizontal else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isWeekVerticalScrollLocked = true
            weekDragTranslation = rubberBandedWeekOffset(value.translation.width, pageWidth: pageWidth)
        }
    }

    private func handleWeekDragEnded(_ value: DragGesture.Value, pageWidth: CGFloat) {
        defer {
            weekDragAxis = nil
        }

        guard canBeginWeekDrag, weekDragAxis == .horizontal else {
            isWeekVerticalScrollLocked = false
            withAnimation(.snappy(duration: 0.32, extraBounce: 0.05)) {
                weekDragTranslation = 0
            }
            return
        }

        let pageWidth = max(pageWidth, 1)
        let currentOffset = weekDragTranslation
        let predictedOffset = value.predictedEndTranslation.width

        // Land on the next/previous week when the page is dragged past its
        // halfway point, or when a quick flick is projected to carry it there.
        // Otherwise settle back to the current week.
        let landingOffset = abs(predictedOffset) > abs(currentOffset) ? predictedOffset : currentOffset
        let shouldMove = abs(landingOffset) > pageWidth * 0.5

        guard shouldMove else {
            withAnimation(.snappy(duration: 0.32, extraBounce: 0.08)) {
                weekDragTranslation = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                isWeekVerticalScrollLocked = false
            }
            return
        }

        let direction = landingOffset < 0 ? 1 : -1
        let exitOffset = direction > 0 ? -pageWidth : pageWidth

        // Slide the current page fully off screen, then show the new week with
        // animation suppressed so the offset reset is invisible. Updating from
        // the animation's completion callback keeps it perfectly
        // in sync with the end of the slide instead of guessing a delay.
        isWeekCommitInProgress = true
        withAnimation(.snappy(duration: 0.3), completionCriteria: .logicallyComplete) {
            weekDragTranslation = exitOffset
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                setWeekStart(Calendar.current.date(byAdding: .day, value: direction * 7, to: weekStart) ?? weekStart)
                weekDragTranslation = 0
                isWeekCommitInProgress = false
                isWeekVerticalScrollLocked = false
            }
        }
    }

    private func date(for day: Weekday, in targetWeekStart: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: day.rawValue - 1, to: targetWeekStart) ?? targetWeekStart
    }

    private func dayOfMonth(for day: Weekday, in targetWeekStart: Date) -> Int {
        Calendar.current.component(.day, from: date(for: day, in: targetWeekStart))
    }

    private func isToday(_ day: Weekday, in targetWeekStart: Date) -> Bool {
        Calendar.current.isDateInToday(date(for: day, in: targetWeekStart))
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

    private func snappedSessionStartMinutes(for yPosition: CGFloat, durationMinutes: Int) -> Int {
        let rawMinutes = dayStartHour * 60 + Int((max(yPosition, 0) / hourHeight) * 60)
        let snappedMinutes = Int((Double(rawMinutes) / 30.0).rounded()) * 30
        let latestStart = dayEndHour * 60 - durationMinutes

        return max(
            dayStartHour * 60,
            min(snappedMinutes, max(dayStartHour * 60, latestStart))
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

                weekPager(summary)
            }
            .background(AppStyle.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isBulkSelectionModeEnabled {
                    bulkSelectionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.24), value: isBulkSelectionModeEnabled)
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let url = prepareICSFile() {
                            fileExport = FileExportItem(url: url)
                        } else {
                            financeSendNotice = FinanceSendNotice(
                                title: "Nothing to Export",
                                message: "This week has no events to include in the calendar file."
                            )
                        }
                    } label: {
                        Label("Export Calendar", systemImage: "calendar")
                    }
                    .disabled(
                        isBulkSelectionModeEnabled ||
                            (sessionsForWeek.isEmpty &&
                                courtBookingsForWeek.isEmpty &&
                                summary.socialSessionsByDay.values.allSatisfy(\.isEmpty))
                    )
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sendToFinanceTracker()
                    } label: {
                        Label("Send to Finance Tracker", systemImage: "dollarsign.circle")
                    }
                    .disabled(sessionsForWeek.isEmpty || isBulkSelectionModeEnabled)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if isBulkSelectionModeEnabled {
                        Button {
                            cancelBulkSelection()
                        } label: {
                            Label("Cancel Bulk Selection", systemImage: "xmark.circle")
                        }
                        .tint(.blue)
                    } else {
                        Menu {
                            Button {
                                beginBulkSelection(.bookCourts)
                            } label: {
                                Label("Book Courts", systemImage: "sportscourt")
                            }
                            .disabled(unbookedSessionsForWeek.isEmpty)

                            Button {
                                beginBulkSelection(.setStatus)
                            } label: {
                                Label("Set Status", systemImage: "checklist")
                            }
                        } label: {
                            Label("Bulk Actions", systemImage: "checklist")
                        }
                        .disabled(sessionsForWeek.isEmpty)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        isResetConfirmationPresented = true
                    } label: {
                        Label("Move to Next Week", systemImage: "arrow.forward")
                    }
                    .disabled(sessionsForWeek.isEmpty || isBulkSelectionModeEnabled)
                }

            }
            .confirmationDialog(
                "Move this week's sessions to next week?",
                isPresented: $isResetConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Move Sessions", role: .destructive) {
                    moveSessionsToNextWeek()
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This moves the current week's sessions to next week, keeps their students and fees, then marks them Unscheduled and clears booked court numbers.")
            }
            .sheet(item: $editor) { editor in
                SessionEditorView(editor: editor)
            }
            .sheet(item: $courtBookingEditor) { editor in
                CourtBookingEditorView(editor: editor)
            }
            .sheet(item: $socialSessionEditor) { editor in
                SocialSessionEditorView(editor: editor)
            }
            .sheet(isPresented: $isMassCourtBookingSheetPresented) {
                MassCourtBookingSheet(selectedCount: selectedBulkSessions.count) { courtNumber in
                    applyMassCourtBooking(courtNumber: courtNumber)
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isMassStatusSheetPresented) {
                MassSessionStatusSheet(selectedCount: selectedBulkSessions.count) { status in
                    applyMassStatus(status)
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
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
            .onAppear {
                assignVisibleWeekToUnscopedRecordsIfNeeded()
            }
        }
    }

    private func weekPager(_ summary: ScheduleSummary) -> some View {
        GeometryReader { proxy in
            let pageWidth = max(proxy.size.width, 1)

            ZStack {
                weekPage(
                    scheduleSummary(for: previousWeekStart),
                    weekStart: previousWeekStart,
                    isInteractive: false
                )
                .offset(x: weekDragTranslation - pageWidth)
                .allowsHitTesting(false)

                weekPage(
                    summary,
                    weekStart: weekStart,
                    isInteractive: true
                )
                .offset(x: weekDragTranslation)

                weekPage(
                    scheduleSummary(for: nextWeekStart),
                    weekStart: nextWeekStart,
                    isInteractive: false
                )
                .offset(x: weekDragTranslation + pageWidth)
                .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(weekSwipeGesture(pageWidth: pageWidth))
        }
    }

    private func weekPage(_ summary: ScheduleSummary, weekStart targetWeekStart: Date, isInteractive: Bool) -> some View {
        VStack(spacing: 0) {
            dayHeaderRow(for: targetWeekStart)
                .padding(.horizontal, calendarHorizontalPadding)

            ScrollView(.vertical) {
                grid(summary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, calendarHorizontalPadding)
                    .padding(.bottom, 28)
            }
            .scrollDisabled(
                isWeekVerticalScrollLocked ||
                    sessionDrag != nil ||
                    draftSelection != nil
            )
        }
        .allowsHitTesting(isInteractive)
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

    private func dayHeaderRow(for targetWeekStart: Date) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeAxisWidth, height: dayHeaderHeight)
            ForEach(Weekday.allCases) { day in
                VStack(spacing: 2) {
                    Text(String(day.name.prefix(3)))
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(isToday(day, in: targetWeekStart) ? Color.accentColor : Color.secondary)
                    Text("\(dayOfMonth(for: day, in: targetWeekStart))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isToday(day, in: targetWeekStart) ? .white : .primary)
                        .frame(width: 28, height: 28)
                        .background {
                            if isToday(day, in: targetWeekStart) {
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
                Color.clear
                    .onAppear {
                        updateGridDayColumnWidth(proxy.size.width)
                    }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        updateGridDayColumnWidth(newWidth)
                    }
                    .allowsHitTesting(false)

                SessionGridInteractionOverlay(
                    isEnabled: pendingDraftSelection == nil &&
                        selectedCourtBooking == nil &&
                        !isWeekCommitInProgress,
                    containsSession: { location in
                        sessionAtGridLocation(
                            at: location,
                            gridWidth: proxy.size.width,
                            summary: summary
                        ) != nil
                    },
                    canMoveSession: { location in
                        guard let session = sessionAtGridLocation(
                            at: location,
                            gridWidth: proxy.size.width,
                            summary: summary
                        ) else {
                            return false
                        }
                        return canDragSession(session)
                    },
                    onTap: { location in
                        guard let session = sessionAtGridLocation(
                            at: location,
                            gridWidth: proxy.size.width,
                            summary: summary
                        ) else { return }
                        handleSessionTap(session)
                    },
                    onMoveBegan: { location in
                        guard let session = sessionAtGridLocation(
                            at: location,
                            gridWidth: proxy.size.width,
                            summary: summary
                        ) else { return }
                        beginSessionDrag(session, from: session.weekday)
                    },
                    onMoveChanged: { translation in
                        guard let sessionDrag else { return }
                        handleSessionDragChanged(
                            sessionDrag.session,
                            from: sessionDrag.session.weekday,
                            translation: translation
                        )
                    },
                    onMoveEnded: {
                        handleSessionDragEnded()
                    },
                    onMoveCancelled: {
                        cancelSessionDrag()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .zIndex(2)

                if let sessionDrag {
                    sessionDragPreview(sessionDrag, gridWidth: proxy.size.width)
                        .zIndex(3)
                        .allowsHitTesting(false)
                }

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
                        onSocials: {
                            openSocialSessionEditor(with: pendingDraftSelection)
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
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.82), value: sessionDrag?.targetDay.rawValue)
        .animation(.spring(response: 0.2, dampingFraction: 0.82), value: sessionDrag?.targetStartMinutes)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: pendingDraftSelection)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: selectedCourtBooking?.persistentModelID)
        .contentShape(Rectangle())
    }

    private func weekSwipeGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                handleWeekDragChanged(value, pageWidth: pageWidth)
            }
            .onEnded { value in
                handleWeekDragEnded(value, pageWidth: pageWidth)
            }
    }

    private func updateGridDayColumnWidth(_ gridWidth: CGFloat) {
        let width = max((gridWidth - timeAxisWidth) / CGFloat(Weekday.allCases.count), 1)
        guard abs(width - gridDayColumnWidth) > 0.5 else { return }

        DispatchQueue.main.async {
            gridDayColumnWidth = width
        }
    }

    private func sessionAtGridLocation(
        at location: CGPoint,
        gridWidth: CGFloat,
        summary: ScheduleSummary
    ) -> CoachingSession? {
        guard location.y >= 0,
              location.y <= totalGridHeight,
              location.x >= timeAxisWidth else {
            return nil
        }

        let dayColumnWidth = max(
            (gridWidth - timeAxisWidth) / CGFloat(Weekday.allCases.count),
            1
        )
        let dayIndex = Int((location.x - timeAxisWidth) / dayColumnWidth)
        guard Weekday.allCases.indices.contains(dayIndex) else { return nil }

        let day = Weekday.allCases[dayIndex]
        let minuteAtLocation = Double(dayStartHour * 60) +
            Double(location.y / hourHeight) * 60

        return summary.sessions(for: day).last { session in
            minuteAtLocation >= Double(minutesOfDay(session.startTime)) &&
                minuteAtLocation < Double(minutesOfDay(session.endTime))
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
                isEnabled: canBeginGridSelection,
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
                let isDragging = sessionDrag?.session.persistentModelID == session.persistentModelID
                SessionBlock(
                    session: session,
                    bulkSelectionAction: bulkSelectionAction,
                    isBulkSelectionEligible: isEligibleForBulkSelection(session),
                    isBulkSelectionSelected: bulkSessionSelection.contains(session.persistentModelID)
                )
                    .frame(height: blockHeight(for: session))
                    .padding(.horizontal, 2)
                    .offset(y: yOffset(for: session))
                    .opacity(isDragging ? 0.22 : 1)
            }

            ForEach(summary.courtBookings(for: day)) { booking in
                CourtBookingBlock(booking: booking)
                    .frame(height: blockHeight(for: booking))
                    .padding(.horizontal, 2)
                    .offset(y: yOffset(for: booking))
                    .onTapGesture {
                        guard !isBulkSelectionModeEnabled else { return }
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

    private func openSocialSessionEditor(with selection: DraftSessionSelection) {
        socialSessionEditor = SocialSessionEditor(
            weekStart: weekStart,
            preselectedDay: selection.day,
            preselectedStartTime: time(for: selection.startMinutes),
            preselectedEndTime: time(for: selection.endMinutes)
        )
    }

    private var bulkSelectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedBulkSessions.count) selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Button(areAllEligibleBulkSessionsSelected ? "Clear" : "Select All") {
                toggleAllBulkSelections()
            }
            .buttonStyle(.bordered)

            Button {
                presentBulkActionEditor()
            } label: {
                Label(
                    bulkSelectionAction?.commitTitle ?? "Apply",
                    systemImage: bulkSelectionAction?.iconName ?? "checkmark.circle.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedBulkSessions.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func handleSessionTap(_ session: CoachingSession) {
        if isBulkSelectionModeEnabled {
            toggleBulkSelection(for: session)
            return
        }

        editor = SessionEditor(session: session, weekStart: weekStart)
    }

    private func beginBulkSelection(_ action: BulkSessionAction) {
        pendingDraftSelection = nil
        draftSelection = nil
        selectedCourtBooking = nil
        sessionDrag = nil
        bulkSessionSelection.removeAll()
        bulkSelectionAction = action
    }

    private func cancelBulkSelection() {
        bulkSelectionAction = nil
        bulkSessionSelection.removeAll()
        isMassCourtBookingSheetPresented = false
        isMassStatusSheetPresented = false
    }

    private func toggleBulkSelection(for session: CoachingSession) {
        guard isEligibleForBulkSelection(session),
              belongsToVisibleWeek(session.weekStart) else { return }

        let id = session.persistentModelID
        if bulkSessionSelection.contains(id) {
            bulkSessionSelection.remove(id)
        } else {
            bulkSessionSelection.insert(id)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func toggleAllBulkSelections() {
        if areAllEligibleBulkSessionsSelected {
            bulkSessionSelection.removeAll()
        } else {
            bulkSessionSelection = Set(
                eligibleBulkSessions.map(\.persistentModelID)
            )
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func presentBulkActionEditor() {
        guard !selectedBulkSessions.isEmpty else { return }

        switch bulkSelectionAction {
        case .bookCourts:
            isMassCourtBookingSheetPresented = true
        case .setStatus:
            isMassStatusSheetPresented = true
        case nil:
            break
        }
    }

    private func applyMassCourtBooking(courtNumber: String) {
        let trimmedCourtNumber = courtNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bulkSelectionAction == .bookCourts,
              !trimmedCourtNumber.isEmpty else { return }

        for session in selectedBulkSessions {
            session.courtNumber = trimmedCourtNumber
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        cancelBulkSelection()
    }

    private func applyMassStatus(_ status: SessionStatus) {
        guard bulkSelectionAction == .setStatus else { return }

        for session in selectedBulkSessions {
            session.status = status.rawValue
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        cancelBulkSelection()
    }

    private func isEligibleForBulkSelection(_ session: CoachingSession) -> Bool {
        switch bulkSelectionAction {
        case .bookCourts:
            return isCourtUnbooked(session)
        case .setStatus:
            return true
        case nil:
            return false
        }
    }

    private func isCourtUnbooked(_ session: CoachingSession) -> Bool {
        session.courtNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canBeginGridSelection: Bool {
        !isBulkSelectionModeEnabled &&
            pendingDraftSelection == nil &&
            selectedCourtBooking == nil &&
            sessionDrag == nil &&
            !isWeekCommitInProgress
    }

    private func canDragSession(_ session: CoachingSession) -> Bool {
        isCourtUnbooked(session) &&
            !isBulkSelectionModeEnabled &&
            pendingDraftSelection == nil &&
            draftSelection == nil &&
            selectedCourtBooking == nil &&
            !isWeekCommitInProgress
    }

    private func beginSessionDrag(_ session: CoachingSession, from day: Weekday) {
        guard canDragSession(session),
              sessionDrag == nil else { return }

        let startMinutes = minutesOfDay(session.startTime)
        let endMinutes = minutesOfDay(session.endTime)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pendingDraftSelection = nil
            selectedCourtBooking = nil
            sessionDrag = SessionDragState(
                session: session,
                targetDay: day,
                targetStartMinutes: startMinutes,
                targetEndMinutes: endMinutes,
                isValid: true
            )
        }
    }

    private func handleSessionDragChanged(
        _ session: CoachingSession,
        from day: Weekday,
        translation: CGSize
    ) {
        guard canDragSession(session) else { return }

        let dayColumnWidth = max(gridDayColumnWidth, 1)
        let duration = durationMinutes(for: session)
        let originalStart = minutesOfDay(session.startTime)
        let originalYOffset = CGFloat(originalStart - dayStartHour * 60) / 60.0 * hourHeight
        let targetStart = snappedSessionStartMinutes(
            for: originalYOffset + translation.height,
            durationMinutes: duration
        )
        let dayOffset = Int((translation.width / dayColumnWidth).rounded())
        let targetDayRaw = min(max(day.rawValue + dayOffset, Weekday.monday.rawValue), Weekday.sunday.rawValue)
        let targetDay = Weekday(rawValue: targetDayRaw) ?? day
        let targetEnd = targetStart + duration
        let isValid = isValidSessionMove(
            session,
            targetDay: targetDay,
            startMinutes: targetStart,
            endMinutes: targetEnd
        )

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pendingDraftSelection = nil
            selectedCourtBooking = nil
            sessionDrag = SessionDragState(
                session: session,
                targetDay: targetDay,
                targetStartMinutes: targetStart,
                targetEndMinutes: targetEnd,
                isValid: isValid
            )
        }
    }

    private func handleSessionDragEnded() {
        guard let sessionDrag else {
            return
        }

        defer {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                self.sessionDrag = nil
            }
        }

        guard sessionDrag.isValid else {
            return
        }

        sessionDrag.session.dayOfWeek = sessionDrag.targetDay.rawValue
        sessionDrag.session.startTime = time(for: sessionDrag.targetStartMinutes)
        sessionDrag.session.endTime = time(for: sessionDrag.targetEndMinutes)
    }

    private func cancelSessionDrag() {
        guard sessionDrag != nil else { return }

        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            sessionDrag = nil
        }
    }

    private func isValidSessionMove(
        _ movingSession: CoachingSession,
        targetDay: Weekday,
        startMinutes: Int,
        endMinutes: Int
    ) -> Bool {
        guard startMinutes >= dayStartHour * 60,
              endMinutes <= dayEndHour * 60,
              endMinutes > startMinutes else {
            return false
        }

        let movingID = movingSession.persistentModelID
        let hasSessionOverlap = sessions.contains { session in
            session.persistentModelID != movingID &&
                belongsToVisibleWeek(session.weekStart) &&
                session.dayOfWeek == targetDay.rawValue &&
                startMinutes < minutesOfDay(session.endTime) &&
                endMinutes > minutesOfDay(session.startTime)
        }
        guard !hasSessionOverlap else { return false }

        let hasCourtBookingOverlap = courtBookings.contains { booking in
            belongsToVisibleWeek(booking.weekStart) &&
                booking.dayOfWeek == targetDay.rawValue &&
                startMinutes < minutesOfDay(booking.endTime) &&
                endMinutes > minutesOfDay(booking.startTime)
        }
        guard !hasCourtBookingOverlap else { return false }

        let hasSocialOverlap = socialSessions.contains { social in
            Calendar.current.isDate(Self.monday(of: social.weekStart), inSameDayAs: weekStart) &&
                social.dayOfWeek == targetDay.rawValue &&
                startMinutes < minutesOfDay(social.endTime) &&
                endMinutes > minutesOfDay(social.startTime)
        }

        return !hasSocialOverlap
    }

    private func sessionDragPreview(_ drag: SessionDragState, gridWidth: CGFloat) -> some View {
        let dayColumnWidth = max((gridWidth - timeAxisWidth) / CGFloat(Weekday.allCases.count), 1)
        let x = timeAxisWidth + CGFloat(drag.targetDay.rawValue - 1) * dayColumnWidth + dayColumnWidth / 2
        let y = CGFloat(drag.targetStartMinutes - dayStartHour * 60) / 60.0 * hourHeight + height(for: drag) / 2

        return SessionBlock(session: drag.session)
            .frame(width: max(dayColumnWidth - 4, 24), height: height(for: drag))
            .scaleEffect(1.02)
            .opacity(drag.isValid ? 0.94 : 0.72)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(drag.isValid ? Color.accentColor.opacity(0.8) : Color.red.opacity(0.9), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
            .position(x: x, y: y)
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

    private func height(for drag: SessionDragState) -> CGFloat {
        let duration = drag.targetEndMinutes - drag.targetStartMinutes
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
        guard let content = generateICSContent(),
              let data = content.data(using: .utf8) else { return nil }

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

    private func moveSessionsToNextWeek() {
        let nextWeek = Self.monday(of: Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart)
        for session in sessionsForWeek {
            session.weekStart = nextWeek
            session.status = SessionStatus.unscheduled.rawValue
            session.courtNumber = ""
        }
        setWeekStart(nextWeek)
    }

    private func sessionName(for session: CoachingSession) -> String {
        let studentList = session.students
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.name)
            .joined(separator: ", ")

        return studentList.isEmpty ? "\(session.venue) coaching" : studentList
    }

    private func generateICSContent() -> String? {
        let calendar = Calendar.current

        // DTSTAMP must be UTC per RFC 5545.
        let utcFormatter = DateFormatter()
        utcFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        utcFormatter.timeZone = TimeZone(identifier: "UTC")
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")

        // Event times are written as floating local time (no trailing "Z"), so
        // "6pm Tuesday" always imports as 6pm regardless of the viewer's
        // timezone rather than being shifted by a UTC conversion.
        let floatingFormatter = DateFormatter()
        floatingFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        floatingFormatter.timeZone = calendar.timeZone
        floatingFormatter.locale = Locale(identifier: "en_US_POSIX")

        let stamp = utcFormatter.string(from: .now)

        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//CoachPlanner//Sessions//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH"
        ]

        var eventCount = 0

        // Google Calendar deduplicates by UID: any two VEVENTs sharing a UID
        // cause all but the first to be silently dropped on import. Guarantee a
        // unique UID per event (appending a counter only when a genuine
        // collision occurs, so stable events keep a stable UID across exports).
        var usedUIDs = Set<String>()
        func uniqueUID(_ base: String) -> String {
            var candidate = base
            var suffix = 2
            while usedUIDs.contains(candidate) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            usedUIDs.insert(candidate)
            return candidate + "-coachplanner@local"
        }

        func weekKey(_ recordWeekStart: Date?) -> String {
            let normalized = Self.monday(of: recordWeekStart ?? weekStart)
            return String(Int(normalized.timeIntervalSince1970))
        }

        for session in sessionsForWeek {
            guard let eventDates = eventDates(
                dayOfWeek: session.dayOfWeek,
                startTime: session.startTime,
                endTime: session.endTime,
                calendar: calendar
            ) else { continue }

            let dtStart = floatingFormatter.string(from: eventDates.start)
            let dtEnd = floatingFormatter.string(from: eventDates.end)
            let uid = uniqueUID([
                "session",
                weekKey(session.weekStart),
                String(session.dayOfWeek),
                String(minutesOfDay(session.startTime)),
                String(minutesOfDay(session.endTime)),
                String(Int(session.createdAt.timeIntervalSince1970 * 1000))
            ].joined(separator: "-"))
            let status = session.statusValue

            let studentList = session.students
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map(\.name)
                .joined(separator: ", ")

            let trimmedCourt = session.courtNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCourtBooked = !trimmedCourt.isEmpty
            let location = trimmedCourt.isEmpty ? session.venue : "\(session.venue), Court \(trimmedCourt)"

            let baseSummary = studentList.isEmpty
                ? "Unassigned Session"
                : studentList
            let summary = calendarTitle(
                base: baseSummary,
                status: status,
                isCourtBooked: isCourtBooked
            )

            var eventLines = [
                "BEGIN:VEVENT",
                "UID:\(uid)",
                "DTSTAMP:\(stamp)",
                "DTSTART:\(dtStart)",
                "DTEND:\(dtEnd)",
                "SUMMARY:\(icsEscape(summary))"
            ]
            if let description = session.sessionDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                eventLines.append("DESCRIPTION:\(icsEscape(description))")
            }
            eventLines += [
                "LOCATION:\(icsEscape(location))",
                "STATUS:\(icsStatus(for: status))",
                "END:VEVENT"
            ]
            lines += eventLines
            eventCount += 1
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
            let uid = uniqueUID([
                "court",
                weekKey(booking.weekStart),
                String(booking.dayOfWeek),
                String(minutesOfDay(booking.startTime)),
                String(minutesOfDay(booking.endTime)),
                String(Int(booking.createdAt.timeIntervalSince1970 * 1000))
            ].joined(separator: "-"))
            lines += [
                "BEGIN:VEVENT",
                "UID:\(uid)",
                "DTSTAMP:\(stamp)",
                "DTSTART:\(floatingFormatter.string(from: eventDates.start))",
                "DTEND:\(floatingFormatter.string(from: eventDates.end))",
                "SUMMARY:\(icsEscape(summary))",
                "LOCATION:\(icsEscape(location))",
                "STATUS:CONFIRMED",
                "END:VEVENT"
            ]
            eventCount += 1
        }

        for social in socialSessionsForWeek {
            guard let eventDates = eventDates(
                dayOfWeek: social.dayOfWeek,
                startTime: social.startTime,
                endTime: social.endTime,
                calendar: calendar
            ) else { continue }

            let trimmedCourts = social.courtNumbersList.joined(separator: ", ")
            let hasCourts = !trimmedCourts.isEmpty
            let location = hasCourts ? "\(social.venue), Courts \(trimmedCourts)" : social.venue

            let baseTitle = social.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = baseTitle.isEmpty ? "Badminton Socials" : baseTitle
            let uid = uniqueUID([
                "social",
                weekKey(social.weekStart),
                String(social.dayOfWeek),
                String(minutesOfDay(social.startTime)),
                String(minutesOfDay(social.endTime)),
                String(Int(social.createdAt.timeIntervalSince1970 * 1000))
            ].joined(separator: "-"))

            lines += [
                "BEGIN:VEVENT",
                "UID:\(uid)",
                "DTSTAMP:\(stamp)",
                "DTSTART:\(floatingFormatter.string(from: eventDates.start))",
                "DTEND:\(floatingFormatter.string(from: eventDates.end))",
                "SUMMARY:\(icsEscape(summary))",
                "LOCATION:\(icsEscape(location))",
                "STATUS:CONFIRMED",
                "END:VEVENT"
            ]
            eventCount += 1
        }

        guard eventCount > 0 else { return nil }

        lines.append("END:VCALENDAR")
        return lines.flatMap(foldedICSLines).joined(separator: "\r\n") + "\r\n"
    }

    private func icsStatus(for status: SessionStatus) -> String {
        status == .confirmed ? "CONFIRMED" : "TENTATIVE"
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

private enum BulkSessionAction: Equatable {
    case bookCourts
    case setStatus

    var commitTitle: String {
        switch self {
        case .bookCourts: return "Book"
        case .setStatus: return "Set Status"
        }
    }

    var iconName: String {
        switch self {
        case .bookCourts: return "checkmark.circle.fill"
        case .setStatus: return "checklist"
        }
    }

    var unavailableTitle: String {
        switch self {
        case .bookCourts: return "Already booked"
        case .setStatus: return "Unavailable"
        }
    }
}

private struct MassCourtBookingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selectedCount: Int
    let onBook: (String) -> Void

    @State private var courtNumber = ""
    @FocusState private var isCourtNumberFocused: Bool

    private var trimmedCourtNumber: String {
        courtNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Court number", text: $courtNumber)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($isCourtNumberFocused)
                } header: {
                    Text("Court Number")
                } footer: {
                    Text("This court number will be assigned to all \(selectedCount) selected \(selectedCount == 1 ? "session" : "sessions").")
                }
            }
            .navigationTitle("Book Courts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Book") {
                        onBook(trimmedCourtNumber)
                        dismiss()
                    }
                    .disabled(trimmedCourtNumber.isEmpty)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    isCourtNumberFocused = true
                }
            }
        }
    }
}

private struct MassSessionStatusSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selectedCount: Int
    let onSelect: (SessionStatus) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SessionStatus.allCases) { status in
                        Button {
                            onSelect(status)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: status.iconName)
                                    .foregroundStyle(status.color)
                                    .frame(width: 22)

                                Text(status.rawValue)
                                    .foregroundStyle(.primary)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("The selected status will be applied to all \(selectedCount) \(selectedCount == 1 ? "session" : "sessions").")
                }
            }
            .navigationTitle("Set Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private enum WeekDragAxis {
    case horizontal
    case vertical
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
    let isEnabled: Bool
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
        recognizer.minimumPressDuration = GridGestureTuning.holdDuration
        recognizer.allowableMovement = GridGestureTuning.preHoldMovementTolerance
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        context.coordinator.recognizer = recognizer

        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.day = day
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var day: Weekday
        var onChanged: (Weekday, CGFloat, CGFloat) -> Void
        var onEnded: (Weekday, CGFloat, CGFloat) -> Void
        var onCancelled: () -> Void
        weak var recognizer: UILongPressGestureRecognizer?
        private var startY: CGFloat?
        private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

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
                feedbackGenerator.impactOccurred()
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
                let wasActive = startY != nil
                startY = nil
                if wasActive {
                    onCancelled()
                }
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}

private struct SessionGridInteractionOverlay: UIViewRepresentable {
    let isEnabled: Bool
    let containsSession: (CGPoint) -> Bool
    let canMoveSession: (CGPoint) -> Bool
    let onTap: (CGPoint) -> Void
    let onMoveBegan: (CGPoint) -> Void
    let onMoveChanged: (CGSize) -> Void
    let onMoveEnded: () -> Void
    let onMoveCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            containsSession: containsSession,
            canMoveSession: canMoveSession,
            onTap: onTap,
            onMoveBegan: onMoveBegan,
            onMoveChanged: onMoveChanged,
            onMoveEnded: onMoveEnded,
            onMoveCancelled: onMoveCancelled
        )
    }

    func makeUIView(context: Context) -> InteractionView {
        let view = InteractionView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = true
        let coordinator = context.coordinator
        view.shouldReceiveTouch = { [weak coordinator] location in
            guard let coordinator else { return false }
            return coordinator.isEnabled && coordinator.containsSession(location)
        }

        let tapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tapRecognizer.cancelsTouchesInView = false

        let moveRecognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMove(_:))
        )
        moveRecognizer.minimumPressDuration = GridGestureTuning.holdDuration
        moveRecognizer.allowableMovement = GridGestureTuning.preHoldMovementTolerance
        moveRecognizer.cancelsTouchesInView = false
        moveRecognizer.delaysTouchesBegan = false
        moveRecognizer.delaysTouchesEnded = false
        moveRecognizer.delegate = context.coordinator

        context.coordinator.moveRecognizer = moveRecognizer
        view.addGestureRecognizer(tapRecognizer)
        view.addGestureRecognizer(moveRecognizer)
        return view
    }

    func updateUIView(_ uiView: InteractionView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.containsSession = containsSession
        context.coordinator.canMoveSession = canMoveSession
        context.coordinator.onTap = onTap
        context.coordinator.onMoveBegan = onMoveBegan
        context.coordinator.onMoveChanged = onMoveChanged
        context.coordinator.onMoveEnded = onMoveEnded
        context.coordinator.onMoveCancelled = onMoveCancelled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var containsSession: (CGPoint) -> Bool
        var canMoveSession: (CGPoint) -> Bool
        var onTap: (CGPoint) -> Void
        var onMoveBegan: (CGPoint) -> Void
        var onMoveChanged: (CGSize) -> Void
        var onMoveEnded: () -> Void
        var onMoveCancelled: () -> Void
        weak var moveRecognizer: UILongPressGestureRecognizer?
        private var startLocation: CGPoint?
        private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

        init(
            isEnabled: Bool,
            containsSession: @escaping (CGPoint) -> Bool,
            canMoveSession: @escaping (CGPoint) -> Bool,
            onTap: @escaping (CGPoint) -> Void,
            onMoveBegan: @escaping (CGPoint) -> Void,
            onMoveChanged: @escaping (CGSize) -> Void,
            onMoveEnded: @escaping () -> Void,
            onMoveCancelled: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.containsSession = containsSession
            self.canMoveSession = canMoveSession
            self.onTap = onTap
            self.onMoveBegan = onMoveBegan
            self.onMoveChanged = onMoveChanged
            self.onMoveEnded = onMoveEnded
            self.onMoveCancelled = onMoveCancelled
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onTap(recognizer.location(in: recognizer.view))
        }

        @objc func handleMove(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view)

            switch recognizer.state {
            case .began:
                startLocation = location
                feedbackGenerator.impactOccurred()
                onMoveBegan(location)
            case .changed:
                guard let startLocation else { return }
                onMoveChanged(
                    CGSize(
                        width: location.x - startLocation.x,
                        height: location.y - startLocation.y
                    )
                )
            case .ended:
                guard startLocation != nil else { return }
                onMoveEnded()
                startLocation = nil
            case .cancelled, .failed:
                let wasActive = startLocation != nil
                startLocation = nil
                if wasActive {
                    onMoveCancelled()
                }
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === moveRecognizer else { return true }
            let location = gestureRecognizer.location(in: gestureRecognizer.view)
            return isEnabled && canMoveSession(location)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }

    final class InteractionView: UIView {
        var shouldReceiveTouch: (CGPoint) -> Bool = { _ in false }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            super.point(inside: point, with: event) && shouldReceiveTouch(point)
        }
    }
}

private enum GridGestureTuning {
    static let holdDuration: TimeInterval = 0.42
    static let preHoldMovementTolerance: CGFloat = 9
}

private struct DraftSessionSelection: Equatable {
    let day: Weekday
    let startMinutes: Int
    let endMinutes: Int
}

private struct SessionDragState {
    let session: CoachingSession
    let targetDay: Weekday
    let targetStartMinutes: Int
    let targetEndMinutes: Int
    let isValid: Bool
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
    static let width: CGFloat = 270

    let timeRange: String
    let onSession: () -> Void
    let onCourtBooking: () -> Void
    let onSocials: () -> Void
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
                    title: "Coaching",
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

                DraftTypeButton(
                    title: "Socials",
                    systemImage: "figure.badminton",
                    tint: .purple,
                    action: onSocials
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
                    title: "Coaching",
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
    var bulkSelectionAction: BulkSessionAction?
    var isBulkSelectionEligible = false
    var isBulkSelectionSelected = false

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
        if isBulkSelectionSelected { return 0.95 }
        return isCourtBooked ? 0.36 : 0.68
    }

    private var strokeWidth: CGFloat {
        isBulkSelectionSelected ? 2.4 : (isCourtBooked ? 0.75 : 1.1)
    }

    private var strokeColor: Color {
        if isBulkSelectionSelected { return .blue }
        return color
    }

    private var shadowColor: Color {
        if isBulkSelectionSelected { return Color.blue.opacity(0.28) }
        return isCourtBooked ? .clear : color.opacity(0.14)
    }

    private var isModeLocked: Bool {
        bulkSelectionAction != nil && !isBulkSelectionEligible
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let bulkSelectionAction {
                Label(
                    isBulkSelectionSelected ? "Selected" : (isBulkSelectionEligible ? "Tap to select" : bulkSelectionAction.unavailableTitle),
                    systemImage: isBulkSelectionSelected ? "checkmark.circle.fill" : (isBulkSelectionEligible ? "circle" : "lock.fill")
                )
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isBulkSelectionEligible ? Color.blue : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
                .stroke(strokeColor.opacity(strokeOpacity), lineWidth: strokeWidth)
        )
        .shadow(color: shadowColor, radius: 5, x: 0, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(isModeLocked ? 0.48 : 1)
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
        .modelContainer(for: [Student.self, StudentHiddenWeek.self, Outsider.self, CoachingSession.self, CourtBooking.self, SocialSession.self, SocialAttendance.self], inMemory: true)
}
