import SwiftUI

public struct TodayView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var practiceTimer: PracticeTimerRuntime
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @State private var quickLogProject: Project?
    @State private var timerProject: Project?
    @State private var quickLogPlan: PlannedSessionContext?
    @State private var timerPlan: PlannedSessionContext?
    @State private var reviewError: String?
    @State private var isCreatingReview = false
    @State private var showingAISettings = false
    @State private var selectedPractice: PracticeRoutine?
    @State private var showingPracticeManager = false
    @State private var practiceError: String?

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
        _practiceTimer = ObservedObject(wrappedValue: viewModel.practiceTimer)
    }

    private var projectsNeedingReview: [Project] {
        viewModel.projectsNeedingReview()
    }

    private var shouldShowReviewPrompt: Bool {
        viewModel.shouldShowReviewPrompt()
    }

    private var todayAgenda: TodayAgenda {
        viewModel.todayAgenda(
            now: practiceTimer.lastRefreshDate,
            calendar: .current
        )
    }

    private var weekRhythm: [StudioWeekDay] {
        StudioPresentation.weekRhythm(
            sessions: viewModel.sessions,
            weekContaining: practiceTimer.lastRefreshDate
        )
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StudioTheme.sectionSpacing) {
                todayHeader
                rhythmSection
                agendaSection

            if let conflicts = calendarViewModel.scheduleDraft?.conflicts, !conflicts.isEmpty {
                Section("Schedule Conflicts") {
                    ForEach(conflicts) { conflict in
                        Label(conflict.detail, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !calendarViewModel.reconciliationItems.isEmpty {
                Section("Calendar Changes") {
                    NavigationLink {
                        CalendarReconciliationView(viewModel: calendarViewModel)
                    } label: {
                        Label("Review \(calendarViewModel.reconciliationItems.count) changes", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }

            if let result = calendarViewModel.lastApplyResult, !result.failed.isEmpty {
                Section("Calendar Writes") {
                    Label("\(result.failed.count) changes failed", systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.red)
                    Button("Retry Failed Changes") {
                        Task { _ = await calendarViewModel.retryFailedChanges() }
                    }
                }
            }

            let plansWithUnscheduledWork = viewModel.learningPlans.filter {
                $0.status == .active && viewModel.unscheduledPlannedSessionCount(for: $0.id) > 0
            }
            if !plansWithUnscheduledWork.isEmpty {
                Section("Unscheduled") {
                    ForEach(plansWithUnscheduledWork) { plan in
                        if let project = viewModel.projects.first(where: { $0.id == plan.projectId }) {
                            NavigationLink {
                                CoursePlanDetailView(viewModel: viewModel, project: project, plan: plan)
                            } label: {
                                LabeledContent(
                                    project.name,
                                    value: "\(viewModel.unscheduledPlannedSessionCount(for: plan.id)) sessions"
                                )
                            }
                        }
                    }
                }
            }

            if shouldShowReviewPrompt || viewModel.reviews.last != nil {
                Section("Review") {
                    if shouldShowReviewPrompt {
                        Button {
                            Task { await createWeeklyReview() }
                        } label: {
                            Label(
                                isCreatingReview ? "Creating Review" : "Weekly Review",
                                systemImage: "sparkles"
                            )
                        }
                        .disabled(isCreatingReview)

                        Button {
                            showingAISettings = true
                        } label: {
                            Label("AI Review Settings", systemImage: "slider.horizontal.3")
                        }

                        ForEach(projectsNeedingReview) { project in
                            Label(project.name, systemImage: "pause.circle")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let latestReview = viewModel.reviews.last {
                        NavigationLink {
                            ReviewView(viewModel: viewModel, review: latestReview)
                        } label: {
                            Label("Latest Review", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                }
            }
            }
            .padding(.horizontal, StudioTheme.pageInset)
            .padding(.bottom, 28)
        }
        .background(StudioTheme.pageBackground.ignoresSafeArea())
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SyncSettingsView(viewModel: viewModel)
                } label: {
                    Image(systemName: syncIcon)
                }
                .accessibilityLabel("iCloud Sync")
            }
        }
        .task {
            await viewModel.refreshSyncSummary()
            await calendarViewModel.refresh()
        }
        .sheet(item: $quickLogProject) { project in
            QuickLogView(viewModel: viewModel, project: project)
        }
        .sheet(item: $timerProject) { project in
            TimerSessionView(viewModel: viewModel, project: project)
        }
        .sheet(item: $quickLogPlan) { context in
            QuickLogView(viewModel: viewModel, project: context.project, plannedSession: context.session)
        }
        .sheet(item: $timerPlan) { context in
            TimerSessionView(viewModel: viewModel, project: context.project, plannedSession: context.session)
        }
        .sheet(isPresented: $showingAISettings) {
            AIReviewSettingsView()
        }
        .sheet(item: $selectedPractice) { routine in
            PracticeTimerView(viewModel: viewModel, routine: routine)
        }
        .sheet(isPresented: $showingPracticeManager) {
            PracticeManagerView(viewModel: viewModel)
        }
        .alert("Review failed", isPresented: .constant(reviewError != nil)) {
            Button("OK") { reviewError = nil }
        } message: {
            Text(reviewError ?? "")
        }
        .alert("Practice Unavailable", isPresented: practiceErrorPresented) {
            Button("OK") { practiceError = nil }
        } message: {
            Text(practiceError ?? "The practice timer could not be opened.")
        }
        .onAppear(perform: restorePendingPractice)
        .onChange(of: practiceTimer.pendingCompletion?.id) { _, _ in
            restorePendingPractice()
        }
    }

    private var todayHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(practiceTimer.lastRefreshDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Your learning rhythm")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(StudioTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var firstRecordSection: some View {
        if let project = viewModel.pendingFirstRecordProject {
            VStack(alignment: .leading, spacing: 10) {
                Text("FIRST RECORD")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(project.name)
                    .font(.headline)
                Text(project.currentNextStep)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    quickLogProject = project
                } label: {
                    Label("Record First Session", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.accent)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var rhythmSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSectionHeader(title: "This week")
            HStack(spacing: 0) {
                ForEach(weekRhythm) { day in
                    VStack(spacing: 8) {
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ZStack {
                            Circle().fill(day.minutes > 0 ? StudioTheme.completed.opacity(0.16) : StudioTheme.mutedSurface)
                            if day.minutes > 0 {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(StudioTheme.completed)
                            }
                        }
                        .frame(width: 34, height: 34)
                        Text(day.minutes > 0 ? "\(day.minutes)m" : "-")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var agendaSection: some View {
        Section {
            if todayAgenda.isEmpty {
                ContentUnavailableView(
                    "Nothing queued",
                    systemImage: "checkmark.circle",
                    description: Text("No planned session, practice occurrence, or Next Step is queued for today.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(todayAgenda.items) { item in
                    agendaItemRow(item)
                }

                if !todayAgenda.cadenceSignals.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Practice cadence", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                        ForEach(todayAgenda.cadenceSignals) { signal in
                            Label(
                                "Missed \(signal.title) on \(signal.occurrenceDate.formatted(date: .abbreviated, time: .omitted))",
                                systemImage: "clock.badge.exclamationmark"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Missed practice cadence: \(signal.title)")
                        }
                        Text("This is a cadence signal, not an overdue task.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
            }
        } header: {
            StudioSectionHeader(title: "Today Agenda", actionTitle: "Manage Practice") {
                showingPracticeManager = true
            }
        }
    }

    private var practiceCards: [StudioPracticeCard] {
        viewModel.practiceCards(
            now: practiceTimer.lastRefreshDate,
            calendar: .current
        )
    }

    @ViewBuilder
    private func agendaItemRow(_ item: TodayAgendaItem) -> some View {
        switch item.source {
        case .plannedSession:
            if let context = plannedSessionContext(for: item) {
                plannedAgendaRow(item, context: context)
            } else {
                agendaFallbackRow(item)
            }
        case .practiceRoutine:
            if let routine = viewModel.practiceRoutines.first(where: { $0.id == item.sourceID }) {
                practiceAgendaRow(item, routine: routine)
            } else {
                agendaFallbackRow(item)
            }
        case .nextStep:
            if let project = viewModel.projects.first(where: { $0.id == item.projectID }) {
                nextStepAgendaRow(item, project: project)
            } else {
                agendaFallbackRow(item)
            }
        }
    }

    private func plannedSessionContext(for item: TodayAgendaItem) -> PlannedSessionContext? {
        guard let session = viewModel.plannedSessions.first(where: { $0.id == item.sourceID }),
              let project = viewModel.projects.first(where: { $0.id == session.projectId }) else {
            return nil
        }
        return PlannedSessionContext(
            session: session,
            project: project,
            phase: viewModel.planPhases.first(where: { $0.id == session.phaseId })
        )
    }

    private func agendaCard<Content: View>(
        _ item: TodayAgendaItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(positionTitle(item.position), systemImage: positionIcon(item.position))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(positionColor(item.position))
                Spacer(minLength: 8)
                agendaOverrideMenu(for: item)
            }
            content()
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func plannedAgendaRow(
        _ item: TodayAgendaItem,
        context: PlannedSessionContext
    ) -> some View {
        agendaCard(item) {
            Text(context.session.title)
                .font(.headline)
            Text("\(context.project.name) · \(context.phase?.title ?? "Plan") · \(context.session.durationMinutes) min")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let expectedProof = context.session.expectedProof, !expectedProof.isEmpty {
                Label(expectedProof, systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let carryover = item.carryover {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Carryover: planning window passed", systemImage: "arrow.uturn.forward.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.notice)
                    if let deadline = carryover.originalDeadline {
                        Text("Original deadline: \(deadline.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Do Today") {
                            setAgendaPosition(.upNext, for: item)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioTheme.accent)
                        .accessibilityLabel("Do carryover today")
                        if let plan = viewModel.activeLearningPlan(for: context.project.id) {
                            NavigationLink("Reschedule") {
                                CoursePlanDetailView(viewModel: viewModel, project: context.project, plan: plan)
                            }
                            .accessibilityLabel("Reschedule carryover")
                        }
                        Button("Skip", role: .destructive) {
                            try? viewModel.skipPlannedSession(context.session.id)
                        }
                        .accessibilityLabel("Skip carryover")
                        if let plan = viewModel.activeLearningPlan(for: context.project.id) {
                            NavigationLink("Revise Plan") {
                                CoursePlanDetailView(viewModel: viewModel, project: context.project, plan: plan)
                            }
                            .accessibilityLabel("Revise plan for carryover")
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            HStack {
                Button {
                    timerPlan = context
                } label: {
                    Label("Start", systemImage: "timer")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Start \(context.session.title)")

                Button {
                    quickLogPlan = context
                } label: {
                    Label("Quick Log", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Quick log \(context.session.title)")

                Spacer()

                if item.carryover == nil {
                    Button(role: .destructive) {
                        try? viewModel.skipPlannedSession(context.session.id)
                    } label: {
                        Image(systemName: "forward.end")
                    }
                    .accessibilityLabel("Skip planned session")
                }

                if context.session.status == .scheduled {
                    Button {
                        try? viewModel.unschedulePlannedSession(context.session.id)
                    } label: {
                        Image(systemName: "calendar.badge.minus")
                    }
                    .accessibilityLabel("Make unscheduled")
                }
            }
        }
    }

    private func practiceAgendaRow(
        _ item: TodayAgendaItem,
        routine: PracticeRoutine
    ) -> some View {
        agendaCard(item) {
            Text(routine.name)
                .font(.headline)
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                openPractice(routine)
            } label: {
                Label("Start practice", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(StudioTheme.practiceColor(routine.color))
            .accessibilityLabel("Start practice \(routine.name)")
        }
    }

    private func nextStepAgendaRow(
        _ item: TodayAgendaItem,
        project: Project
    ) -> some View {
        agendaCard(item) {
            Text(project.name)
                .font(.headline)
            Text(project.currentNextStep)
                .font(.body)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button {
                    timerProject = project
                } label: {
                    Label("Start \(project.defaultDurationMinutes) min", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.accent)
                .accessibilityLabel("Start next step for \(project.name)")

                Button {
                    quickLogProject = project
                } label: {
                    Label("Quick Log", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Quick log next step for \(project.name)")
            }
        }
    }

    private func agendaFallbackRow(_ item: TodayAgendaItem) -> some View {
        agendaCard(item) {
            Text(item.title)
                .font(.headline)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("The source record is no longer available.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func agendaOverrideMenu(for item: TodayAgendaItem) -> some View {
        Menu {
            if item.position != .upNext {
                Button("Make Up Next") { setAgendaPosition(.upNext, for: item) }
            }
            if item.position != .laterToday {
                Button("Later Today") { setAgendaPosition(.laterToday, for: item) }
            }
            if item.position != .optional {
                Button("Optional") { setAgendaPosition(.optional, for: item) }
            }
            if item.position != .skipToday {
                Button("Skip Today") { setAgendaPosition(.skipToday, for: item) }
            } else {
                Button("Restore to Optional") { setAgendaPosition(.optional, for: item) }
            }
            Button("Clear Daily Override") {
                viewModel.clearTodayAgendaOverride(
                    day: practiceTimer.lastRefreshDate,
                    source: item.source,
                    sourceID: item.sourceID
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Change agenda position for \(item.title)")
    }

    private func setAgendaPosition(_ position: TodayAgendaPosition, for item: TodayAgendaItem) {
        viewModel.applyTodayAgendaOverride(
            TodayAgendaOverride(
                day: practiceTimer.lastRefreshDate,
                source: item.source,
                sourceID: item.sourceID,
                position: position
            )
        )
    }

    private func positionTitle(_ position: TodayAgendaPosition) -> String {
        switch position {
        case .upNext: "Up Next"
        case .laterToday: "Later Today"
        case .optional: "Optional"
        case .skipToday: "Skipped Today"
        }
    }

    private func positionIcon(_ position: TodayAgendaPosition) -> String {
        switch position {
        case .upNext: "arrow.right.circle.fill"
        case .laterToday: "clock"
        case .optional: "bookmark"
        case .skipToday: "minus.circle"
        }
    }

    private func positionColor(_ position: TodayAgendaPosition) -> Color {
        switch position {
        case .upNext: StudioTheme.accent
        case .laterToday: .secondary
        case .optional: .secondary
        case .skipToday: Color.secondary.opacity(0.6)
        }
    }

    private var practiceErrorPresented: Binding<Bool> {
        Binding {
            practiceError != nil
        } set: { isPresented in
            if !isPresented { practiceError = nil }
        }
    }

    private func openPractice(_ routine: PracticeRoutine) {
        if practiceTimer.pendingCompletion != nil {
            restorePendingPractice()
            return
        }
        do {
            if practiceTimer.snapshot.activeRoutineId == nil {
                try viewModel.startPractice(routine)
            } else if practiceTimer.snapshot.activeRoutineId != routine.id {
                let activeName = viewModel.practiceRoutines.first {
                    $0.id == practiceTimer.snapshot.activeRoutineId
                }?.name ?? "another routine"
                practiceError = "Finish or discard \(activeName) before starting \(routine.name)."
                return
            }
            selectedPractice = routine
        } catch {
            practiceError = error.localizedDescription
        }
    }

    private func restorePendingPractice() {
        guard let pending = practiceTimer.pendingCompletion else { return }
        let syncedRoutine = viewModel.practiceRoutines.first(where: {
            $0.id == pending.completion.routineId && $0.deletedAt == nil
        })
        let presentation = pending.routinePresentation
        selectedPractice = PracticeRoutine(
            id: pending.completion.routineId,
            name: presentation?.name ?? syncedRoutine?.name ?? "Practice",
            symbolName: presentation?.symbolName ?? syncedRoutine?.symbolName ?? "timer",
            color: presentation?.color ?? syncedRoutine?.color ?? .teal,
            targetMinutes: syncedRoutine?.targetMinutes
                ?? max(1, pending.completion.activeDurationSeconds / 60),
            weekdays: syncedRoutine?.weekdays ?? Set(1...7),
            blocks: syncedRoutine?.orderedBlocks ?? pending.completion.blocks,
            reminderTime: syncedRoutine?.reminderTime,
            isArchived: syncedRoutine?.isArchived ?? true,
            createdAt: syncedRoutine?.createdAt ?? pending.completion.startedAt,
            updatedAt: syncedRoutine?.updatedAt ?? pending.completion.endedAt,
            deletedAt: nil,
            schemaVersion: syncedRoutine?.schemaVersion ?? 1
        )
    }

    private func createWeeklyReview() async {
        isCreatingReview = true
        defer { isCreatingReview = false }
        do {
            _ = try await viewModel.createWeeklyReview(
                periodStart: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast,
                periodEnd: Date()
            )
        } catch {
            reviewError = error.localizedDescription
        }
    }

    private func latestSession(for project: Project) -> LearningSession? {
        viewModel.sessionsForProject(project.id).max { $0.endedAt < $1.endedAt }
    }

    private func reasonText(_ reason: TodayRecommendationReason) -> String {
        switch reason {
        case .userPinned: "Pinned by you"
        case .contractBoundary: "Evidence Contract boundary is due"
        case .confirmedSchedule: "Confirmed schedule"
        case .staleProject: "Oldest meaningful activity"
        }
    }

    @ViewBuilder
    private func plannedSessionRow(_ context: PlannedSessionContext) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(context.session.title)
                .font(.headline)
            Text("\(context.project.name) · \(context.phase?.title ?? "Plan") · \(context.session.durationMinutes) min")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let expectedProof = context.session.expectedProof, !expectedProof.isEmpty {
                Label(expectedProof, systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    timerPlan = context
                } label: {
                    Label("Start", systemImage: "timer")
                }
                .buttonStyle(.borderless)

                Button {
                    quickLogPlan = context
                } label: {
                    Label("Quick Log", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(role: .destructive) {
                    try? viewModel.skipPlannedSession(context.session.id)
                } label: {
                    Image(systemName: "forward.end")
                }
                .accessibilityLabel("Skip planned session")

                if context.session.status == .scheduled {
                    Button {
                        try? viewModel.unschedulePlannedSession(context.session.id)
                    } label: {
                        Image(systemName: "calendar.badge.minus")
                    }
                    .accessibilityLabel("Make unscheduled")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func latestProof(for project: Project) -> Proof? {
        viewModel.proofsForProject(project.id).max { $0.createdAt < $1.createdAt }
    }

    private var syncIcon: String {
        switch viewModel.syncSummary.title {
        case "Synced": "checkmark.icloud"
        case "Syncing": "arrow.triangle.2.circlepath.icloud"
        case "Needs Attention": "exclamationmark.icloud"
        default: "icloud"
        }
    }
}

private struct PracticeRoutineCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let card: StudioPracticeCard
    let action: () -> Void

    private var color: Color {
        StudioTheme.practiceColor(card.routine.color)
    }

    private var todaySeconds: Int {
        card.statistics.todayActiveSeconds
    }

    private var targetSeconds: Int {
        card.targetSeconds
    }

    private var progress: Double {
        min(Double(todaySeconds) / Double(max(targetSeconds, 1)), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    routineIdentity
                    actionButton
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 14) {
                    routineIdentity
                    Spacer(minLength: 4)
                    actionButton
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    PracticeStatisticRow(value: "\(card.statistics.weekCompletionCount)", label: "This week")
                    PracticeStatisticRow(
                        value: StudioDurationFormat.compact(seconds: card.statistics.weekActiveSeconds),
                        label: "Week time"
                    )
                    PracticeStatisticRow(
                        value: StudioDurationFormat.compact(seconds: card.statistics.allTimeActiveSeconds),
                        label: "All time"
                    )
                }
            } else {
                HStack(spacing: 0) {
                    PracticeStatistic(value: "\(card.statistics.weekCompletionCount)", label: "This week")
                    PracticeStatistic(
                        value: StudioDurationFormat.compact(seconds: card.statistics.weekActiveSeconds),
                        label: "Week time"
                    )
                    PracticeStatistic(
                        value: StudioDurationFormat.compact(seconds: card.statistics.allTimeActiveSeconds),
                        label: "All time"
                    )
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var routineIdentity: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(StudioTheme.mutedSurface, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: card.routine.symbolName)
                    .font(.headline)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
            .frame(width: StudioTheme.practiceRingSize, height: StudioTheme.practiceRingSize)
            .accessibilityElement()
            .accessibilityLabel("\(card.routine.name) target progress")
            .accessibilityValue("\(Int(progress * 100)) percent")

            VStack(alignment: .leading, spacing: 5) {
                Text(card.routine.name)
                    .font(.headline)
                Text(
                    "\(StudioDurationFormat.compact(seconds: todaySeconds)) / \(StudioDurationFormat.compact(seconds: targetSeconds)) today"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var actionButton: some View {
        Button(action: action) {
            Label(card.isActiveTimer ? "Resume" : "Start", systemImage: "play.fill")
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .controlSize(dynamicTypeSize.isAccessibilitySize ? .regular : .small)
        .frame(minWidth: 82, minHeight: 44)
        .accessibilityLabel("\(card.isActiveTimer ? "Resume" : "Start") \(card.routine.name)")
    }
}

private struct PracticeStatistic: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .accessibilityElement(children: .combine)
    }
}

private struct PracticeStatisticRow: View {
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
