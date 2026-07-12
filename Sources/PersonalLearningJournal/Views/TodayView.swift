import SwiftUI

public struct TodayView: View {
    @ObservedObject private var viewModel: JournalViewModel
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

    public var body: some View {
        List {
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
        .task { await viewModel.refreshSyncSummary() }
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
