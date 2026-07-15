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

    private var todaysPlan: [PlannedSessionContext] {
        viewModel.todayPlannedSessions()
    }

    private var overduePlan: [PlannedSessionContext] {
        viewModel.overduePlannedSessions()
    }

    private var recommendations: [TodayRecommendation] {
        viewModel.todayRecommendations(now: practiceTimer.lastRefreshDate)
    }

    private var primaryRecommendation: TodayRecommendation? {
        recommendations.first
    }

    private var primaryProject: Project? {
        guard let projectID = primaryRecommendation?.projectId else { return nil }
        return viewModel.projects.first { $0.id == projectID }
    }

    private var weekRhythm: [StudioWeekDay] {
        StudioPresentation.weekRhythm(
            sessions: viewModel.sessions,
            weekContaining: practiceTimer.lastRefreshDate
        )
    }

    private var alternativeRecommendations: [TodayRecommendation] {
        Array(recommendations.dropFirst())
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StudioTheme.sectionSpacing) {
                todayHeader
                rhythmSection
                focusSection
                practiceSection

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

            if !todaysPlan.isEmpty {
                Section("Planned Today") {
                    ForEach(todaysPlan) { context in
                        plannedSessionRow(context)
                    }
                }
            }

            if !overduePlan.isEmpty {
                Section("Overdue") {
                    ForEach(overduePlan) { context in
                        plannedSessionRow(context)
                    }
                }
            }

            let plansWithUnscheduledWork = viewModel.coursePlans.filter {
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

            if primaryRecommendation == nil || !alternativeRecommendations.isEmpty {
                Section("Alternatives") {
                if primaryRecommendation == nil && alternativeRecommendations.isEmpty {
                    ContentUnavailableView(
                        "No Active Next Step",
                        systemImage: "figure.walk",
                        description: Text("Add a Next Step to an active project.")
                    )
                } else {
                    ForEach(alternativeRecommendations) { recommendation in
                        if let project = viewModel.projects.first(where: { $0.id == recommendation.projectId }) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(project.name)
                                .font(.headline)
                            Label(reasonText(recommendation.reason), systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(project.currentNextStep)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let session = latestSession(for: project) {
                                Text("Last: \(session.durationMinutes) min · \(session.actionType.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let proof = latestProof(for: project) {
                                Text("Proof: \(proof.title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button {
                                    timerProject = project
                                } label: {
                                    Label("Start", systemImage: "timer")
                                }
                                Spacer()
                                Button {
                                    quickLogProject = project
                                } label: {
                                    Label("Quick Log", systemImage: "square.and.pencil")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 6)
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
    private var focusSection: some View {
        if let recommendation = primaryRecommendation, let project = primaryProject {
            VStack(alignment: .leading, spacing: 12) {
                Text("PRIMARY RECOMMENDATION")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(project.name)
                    .font(.title2.bold())
                Label(reasonText(recommendation.reason), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                    Button {
                        quickLogProject = project
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Quick Log")
                }
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var practiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioSectionHeader(title: "Practice", actionTitle: "Manage") {
                showingPracticeManager = true
            }

            if practiceCards.isEmpty {
                Button {
                    showingPracticeManager = true
                } label: {
                    Label("Add Practice", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            } else {
                ForEach(practiceCards) { card in
                    PracticeRoutineCard(card: card) {
                        openPractice(card.routine)
                    }
                }
            }
        }
    }

    private var practiceCards: [StudioPracticeCard] {
        viewModel.practiceCards(
            now: practiceTimer.lastRefreshDate,
            calendar: .current
        )
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
