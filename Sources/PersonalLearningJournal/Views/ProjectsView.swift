import SwiftUI

public struct ProjectsView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @State private var showingCreate = false
    @State private var selectedStatus: ProjectStatus = .active

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Project status", selection: $selectedStatus) {
                ForEach(ProjectStatus.allCases, id: \.self) { status in
                    Text("\(status.rawValue.capitalized)  \(count(for: status))").tag(status)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, StudioTheme.pageInset)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(filteredProjects) { project in
                        NavigationLink {
                            ProjectDetailView(viewModel: viewModel, project: project)
                        } label: {
                            projectCard(project)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, StudioTheme.pageInset)
                .padding(.bottom, 24)
            }
        }
        .background(StudioTheme.pageBackground.ignoresSafeArea())
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreate = true
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateProjectView(viewModel: viewModel)
        }
    }

    private var filteredProjects: [Project] {
        StudioPresentation.projects(viewModel.projects, status: selectedStatus)
    }

    private func count(for status: ProjectStatus) -> Int {
        StudioPresentation.projects(viewModel.projects, status: status).count
    }

    private func projectCard(_ project: Project) -> some View {
        let plan = viewModel.activeCoursePlan(for: project.id)
        let sessions = plan.map { viewModel.plannedSessions(for: $0.id) } ?? []
        let progress = StudioPresentation.progress(
            completed: sessions.count { $0.status == .completed },
            total: sessions.count
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: project.lastActionType == .course ? "book.closed.fill" : "square.grid.2x2.fill")
                    .foregroundStyle(StudioTheme.accent)
                Text(project.name).font(.headline)
                Spacer()
                Text(sessions.isEmpty ? (progressedThisWeek(project) ? "Active" : "Idle") : progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.accent)
            }
            if sessions.isEmpty {
                Label(
                    progressedThisWeek(project) ? "Activity this week" : "No activity this week",
                    systemImage: progressedThisWeek(project) ? "checkmark.circle" : "pause.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ProgressView(value: progress)
                    .tint(progress >= 1 ? StudioTheme.completed : StudioTheme.accent)
            }
            Text("Next step")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(project.currentNextStep.isEmpty ? "No next step" : project.currentNextStep)
                    .font(.body.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            if let proof = latestProof(for: project) {
                Label(proof.title, systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func latestSession(for project: Project) -> LearningSession? {
        viewModel.sessionsForProject(project.id).max { $0.endedAt < $1.endedAt }
    }

    private func latestProof(for project: Project) -> Proof? {
        viewModel.proofsForProject(project.id).max { $0.createdAt < $1.createdAt }
    }

    private func progressedThisWeek(_ project: Project) -> Bool {
        let startOfWeek = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? .distantPast
        return viewModel.sessionsForProject(project.id).contains { $0.endedAt >= startOfWeek }
            || viewModel.proofsForProject(project.id).contains { $0.createdAt >= startOfWeek }
    }
}

private struct CreateProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: JournalViewModel
    @State private var name = ""
    @State private var area = ""
    @State private var goal = ""
    @State private var nextStep = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Project", text: $name)
                TextField("Area", text: $area)
                TextField("Goal", text: $goal, axis: .vertical)
                TextField("Next Step", text: $nextStep, axis: .vertical)
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        do {
                            _ = try viewModel.createProject(
                                name: name,
                                area: area,
                                goal: goal,
                                nextStep: nextStep
                            )
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .alert("Could not create project", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private struct ProjectDetailView: View {
    @ObservedObject var viewModel: JournalViewModel
    var project: Project
    @State private var showingEdit = false
    @State private var showingProof = false
    @State private var quickLogProject: Project?
    @State private var timerProject: Project?
    @State private var reviewError: String?
    @State private var isCreatingReview = false
    @State private var showingAISettings = false
    @State private var showingCoursePlanWizard = false

    private var currentProject: Project {
        viewModel.projects.first { $0.id == project.id } ?? project
    }

    private var projectNeedsReview: Bool {
        viewModel.projectsNeedingReview().contains { $0.id == currentProject.id }
    }

    var body: some View {
        List {
            Section("Goal") {
                Text(currentProject.goal)
                Text("Next: \(currentProject.currentNextStep)")
                    .foregroundStyle(.secondary)
            }

            Section("Actions") {
                Button {
                    timerProject = currentProject
                } label: {
                    Label("Start", systemImage: "timer")
                }

                Button {
                    quickLogProject = currentProject
                } label: {
                    Label("Quick Log", systemImage: "square.and.pencil")
                }

                Button {
                    showingProof = true
                } label: {
                    Label("Add Proof", systemImage: "paperclip.badge.plus")
                }
            }

            Section("Study Plan") {
                if let plan = viewModel.activeCoursePlan(for: currentProject.id) {
                    NavigationLink {
                        CoursePlanDetailView(viewModel: viewModel, project: currentProject, plan: plan)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Revision \(plan.revision)")
                                .font(.headline)
                            Text("\(viewModel.plannedSessions(for: plan.id).count) planned sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button {
                        showingCoursePlanWizard = true
                    } label: {
                        Label("Create Study Plan", systemImage: "list.bullet.rectangle")
                    }
                }

                if let draft = viewModel.draftCoursePlan, draft.projectId == currentProject.id {
                    Text("Draft revision \(draft.revision) is ready to review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if projectNeedsReview {
                Section("Review") {
                    Button {
                        Task { await createReview() }
                    } label: {
                        Label(
                            isCreatingReview ? "Creating Review" : "Review This Project",
                            systemImage: "sparkles"
                        )
                    }
                    .disabled(isCreatingReview)

                    Button {
                        showingAISettings = true
                    } label: {
                        Label("AI Review Settings", systemImage: "slider.horizontal.3")
                    }
                }
            }

            Section("Status") {
                Picker("Status", selection: statusBinding) {
                    ForEach(ProjectStatus.allCases, id: \.self) { status in
                        Text(status.rawValue).tag(status)
                    }
                }
            }

            Section("Sessions") {
                ForEach(viewModel.sessionsForProject(currentProject.id)) { session in
                    NavigationLink {
                        SessionDetailView(
                            viewModel: viewModel,
                            project: currentProject,
                            session: session
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.note)
                                .font(.headline)
                            Text("\(session.durationMinutes) min · \(session.actionType.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Proofs") {
                ForEach(viewModel.proofsForProject(currentProject.id)) { proof in
                    NavigationLink {
                        ProofDetailView(
                            proof: proof,
                            projectName: currentProject.name,
                            sessionSummary: sessionSummary(for: proof)
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proof.title)
                                .font(.headline)
                            Text(proof.statement)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Reviews") {
                ForEach(viewModel.reviewsForProject(currentProject.id)) { review in
                    NavigationLink {
                        ReviewView(viewModel: viewModel, review: review)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(review.decisions.first ?? "Weekly Review")
                                .font(.headline)
                            Text(review.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Learning Trail") {
                ForEach(viewModel.trail(for: currentProject.id)) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title)
                            .font(.headline)
                        Text(event.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(currentProject.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingEdit = true
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            EditProjectView(viewModel: viewModel, project: currentProject)
        }
        .sheet(isPresented: $showingProof) {
            AddProofView(viewModel: viewModel, project: currentProject, session: nil)
        }
        .sheet(item: $quickLogProject) { project in
            QuickLogView(viewModel: viewModel, project: project)
        }
        .sheet(item: $timerProject) { project in
            TimerSessionView(viewModel: viewModel, project: project)
        }
        .sheet(isPresented: $showingAISettings) {
            AIReviewSettingsView()
        }
        .sheet(isPresented: $showingCoursePlanWizard) {
            CoursePlanWizardView(viewModel: viewModel, project: currentProject)
        }
        .alert("Review failed", isPresented: .constant(reviewError != nil)) {
            Button("OK") { reviewError = nil }
        } message: {
            Text(reviewError ?? "")
        }
    }

    private var statusBinding: Binding<ProjectStatus> {
        Binding {
            currentProject.status
        } set: { newStatus in
            try? viewModel.updateProjectStatus(projectId: currentProject.id, status: newStatus)
        }
    }

    private func createReview() async {
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

    private func sessionSummary(for proof: Proof) -> String {
        guard let sessionId = proof.sessionId else { return "Project-level Proof" }
        guard let session = viewModel.sessions.first(where: { $0.id == sessionId }) else {
            return "Session unavailable"
        }
        return "\(session.durationMinutes) min · \(session.actionType.rawValue) · \(session.note)"
    }
}

private struct SessionDetailView: View {
    @ObservedObject var viewModel: JournalViewModel
    var project: Project
    var session: LearningSession
    @State private var showingProof = false

    private var proofs: [Proof] {
        viewModel.proofsForSession(session.id)
    }

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Action", value: session.actionType.rawValue)
                LabeledContent("Duration", value: "\(session.durationMinutes) min")
                Text(session.note)
            }

            Section("Next Step") {
                LabeledContent("Before", value: session.nextStepBefore)
                LabeledContent("After", value: session.nextStepAfter)
            }

            Section("Proofs") {
                ForEach(proofs) { proof in
                    NavigationLink {
                        ProofDetailView(
                            proof: proof,
                            projectName: project.name,
                            sessionSummary: "\(session.durationMinutes) min · \(session.actionType.rawValue) · \(session.note)"
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proof.title)
                                .font(.headline)
                            Text(proof.statement)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Session")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingProof = true
                } label: {
                    Label("Add Proof", systemImage: "paperclip.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showingProof) {
            AddProofView(viewModel: viewModel, project: project, session: session)
        }
    }
}

private struct EditProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: JournalViewModel
    var project: Project
    @State private var name: String
    @State private var area: String
    @State private var goal: String
    @State private var nextStep: String
    @State private var errorMessage: String?

    init(viewModel: JournalViewModel, project: Project) {
        self.viewModel = viewModel
        self.project = project
        _name = State(initialValue: project.name)
        _area = State(initialValue: project.area)
        _goal = State(initialValue: project.goal)
        _nextStep = State(initialValue: project.currentNextStep)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Project", text: $name)
                TextField("Area", text: $area)
                TextField("Goal", text: $goal, axis: .vertical)
                TextField("Next Step", text: $nextStep, axis: .vertical)
            }
            .navigationTitle("Edit Project")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            _ = try viewModel.updateProject(
                                projectId: project.id,
                                name: name,
                                area: area,
                                goal: goal,
                                nextStep: nextStep
                            )
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .alert("Could not update project", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
