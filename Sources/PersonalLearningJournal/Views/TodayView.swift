import SwiftUI

public struct TodayView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @State private var quickLogProject: Project?
    @State private var timerProject: Project?
    @State private var quickLogPlan: PlannedSessionContext?
    @State private var timerPlan: PlannedSessionContext?
    @State private var reviewError: String?
    @State private var isCreatingReview = false
    @State private var showingAISettings = false

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
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

    private var focus: StudioFocus? {
        StudioPresentation.focus(projects: viewModel.continueCards, planned: todaysPlan)
    }

    private var weekRhythm: [StudioWeekDay] {
        StudioPresentation.weekRhythm(sessions: viewModel.sessions, weekContaining: Date())
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StudioTheme.sectionSpacing) {
                todayHeader
                rhythmSection
                focusSection

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

            Section("Continue") {
                if viewModel.continueCards.isEmpty {
                    ContentUnavailableView(
                        "No Active Next Step",
                        systemImage: "figure.walk",
                        description: Text("Add a Next Step to an active project.")
                    )
                } else {
                    ForEach(viewModel.continueCards) { project in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(project.name)
                                .font(.headline)
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
        .alert("Review failed", isPresented: .constant(reviewError != nil)) {
            Button("OK") { reviewError = nil }
        } message: {
            Text(reviewError ?? "")
        }
    }

    private var todayHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Your learning rhythm")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(StudioTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if let focus {
            VStack(alignment: .leading, spacing: 12) {
                Text("CURRENT FOCUS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(focus.project.name)
                    .font(.title2.bold())
                Text(focus.planned?.session.title ?? focus.project.currentNextStep)
                    .font(.body)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button {
                        if let planned = focus.planned { timerPlan = planned } else { timerProject = focus.project }
                    } label: {
                        Label("Start \(focus.planned?.session.durationMinutes ?? focus.project.defaultDurationMinutes) min", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.accent)

                    Button {
                        if let planned = focus.planned { quickLogPlan = planned } else { quickLogProject = focus.project }
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
