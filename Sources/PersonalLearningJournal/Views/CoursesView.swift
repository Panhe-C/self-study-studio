import SwiftUI

// MARK: - Course summary projection (pure, testable)

/// One row of the Courses list (spec 3.1): a project plus the learning
/// signals the list surfaces — active plan, current phase, milestone, next
/// step, last confirmed record, and pending adjustment suggestions.
public struct CourseSummary: Equatable, Identifiable, Sendable {
    public let project: Project
    /// The project's active plan revision, resolved exactly like
    /// `JournalViewModel.activeLearningPlan(for:)`. Nil for manual projects.
    public let activePlan: LearningPlan?
    /// First non-completed, non-abandoned phase of the active plan revision,
    /// by ordinal. Nil for manual projects and fully completed plans.
    public let currentPhase: PlanPhase?
    /// The canonical Next Step; falls back to the first incomplete planned
    /// session title when the project has none.
    public let nextStep: String?
    /// Latest session with a confirmed assessment, by `endedAt`.
    public let lastConfirmedRecord: LearningSession?
    public let pendingSuggestionCount: Int

    public var id: UUID { project.id }

    /// The current phase objective — the milestone the course is working
    /// toward right now.
    public var milestone: String? { currentPhase?.objective }

    /// Spec 3.1: a project without an active plan renders as a manual
    /// learning project, no migration required.
    public var isManualProject: Bool { activePlan == nil }

    public init(
        project: Project,
        activePlan: LearningPlan?,
        currentPhase: PlanPhase?,
        nextStep: String?,
        lastConfirmedRecord: LearningSession?,
        pendingSuggestionCount: Int
    ) {
        self.project = project
        self.activePlan = activePlan
        self.currentPhase = currentPhase
        self.nextStep = nextStep
        self.lastConfirmedRecord = lastConfirmedRecord
        self.pendingSuggestionCount = pendingSuggestionCount
    }
}

/// Pure projection from the journal snapshot into the Courses list. It never
/// mutates anything and performs no migration: existing projects, with or
/// without plans, render as-is.
public enum CourseSummaryProjector {
    /// Projects the snapshot into ordered course summaries. Ordering is
    /// deterministic: status groups rank active → idea → paused → completed →
    /// abandoned (legacy `lowFrequency` ranks with active); within a group,
    /// `updatedAt` descending with the project id as tie-breaker. Trashed and
    /// deleted projects never appear.
    public static func project(snapshot: JournalSnapshot) -> [CourseSummary] {
        snapshot.projects
            .filter { !$0.isTrashed && $0.deletedAt == nil }
            .sorted { lhs, rhs in
                let lhsRank = statusRank(lhs.status)
                let rhsRank = statusRank(rhs.status)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { summarize($0, snapshot: snapshot) }
    }

    private static func statusRank(_ status: ProjectStatus) -> Int {
        switch status {
        case .active, .lowFrequency: 0
        case .idea: 1
        case .paused: 2
        case .completed: 3
        case .abandoned: 4
        case .archived, .trash: 5
        }
    }

    private static func summarize(_ project: Project, snapshot: JournalSnapshot) -> CourseSummary {
        let plan = activePlan(for: project, snapshot: snapshot)
        return CourseSummary(
            project: project,
            activePlan: plan,
            currentPhase: currentPhase(for: plan, snapshot: snapshot),
            nextStep: nextStep(for: project, plan: plan, snapshot: snapshot),
            lastConfirmedRecord: lastConfirmedRecord(for: project, snapshot: snapshot),
            pendingSuggestionCount: snapshot.learningAdjustmentSuggestions
                .filter {
                    $0.projectID == project.id && $0.decision == .pending && $0.deletedAt == nil
                }
                .count
        )
    }

    /// Mirrors `JournalViewModel.activeLearningPlan(for:)` so the list and
    /// the detail screens always agree on which revision is active.
    private static func activePlan(for project: Project, snapshot: JournalSnapshot) -> LearningPlan? {
        if let plan = snapshot.learningPlanAggregates(for: project.id)
            .compactMap(\.activeRevision)
            .first?.plan {
            return plan
        }
        guard let activeID = project.activeCoursePlanId else { return nil }
        return snapshot.coursePlans.first { $0.id == activeID }
    }

    private static func currentPhase(for plan: LearningPlan?, snapshot: JournalSnapshot) -> PlanPhase? {
        guard let plan else { return nil }
        return snapshot.planPhases
            .filter { $0.planId == plan.id && $0.deletedAt == nil }
            .sorted { $0.ordinal < $1.ordinal }
            .first { $0.progress != .completed && $0.progress != .abandoned }
    }

    private static func nextStep(
        for project: Project,
        plan: LearningPlan?,
        snapshot: JournalSnapshot
    ) -> String? {
        let canonical = project.currentNextStep.trimmedForJournal
        if !canonical.isEmpty { return canonical }
        guard let plan else { return nil }
        let phaseOrdinals = Dictionary(
            uniqueKeysWithValues: snapshot.planPhases
                .filter { $0.planId == plan.id }
                .map { ($0.id, $0.ordinal) }
        )
        return snapshot.plannedSessions
            .filter {
                $0.planId == plan.id
                    && $0.deletedAt == nil
                    && ($0.status == .unscheduled || $0.status == .scheduled)
            }
            .sorted {
                (phaseOrdinals[$0.phaseId] ?? .max, $0.createdAt)
                    < (phaseOrdinals[$1.phaseId] ?? .max, $1.createdAt)
            }
            .first?.title
    }

    private static func lastConfirmedRecord(
        for project: Project,
        snapshot: JournalSnapshot
    ) -> LearningSession? {
        snapshot.sessions
            .filter { $0.projectId == project.id && $0.deletedAt == nil && $0.assessment != nil }
            .max { $0.endedAt < $1.endedAt }
    }
}

// MARK: - Courses list

/// The vNext Courses tab (spec 3.1, 6.1): every non-trashed project renders
/// as a course summary — projects with an active plan show phase, milestone,
/// and plan signals; manual projects show next step and record history.
/// Cards push the existing project detail, which now also carries pending
/// adjustment suggestions.
public struct CoursesView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @State private var showingCreate = false
    @State private var createdCourseProject: Project?
    @State private var pendingWizardProject: Project?

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
    }

    private var summaries: [CourseSummary] {
        CourseSummaryProjector.project(snapshot: viewModel.snapshot)
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if summaries.isEmpty {
                    ContentUnavailableView(
                        String(localized: "courses.empty.title"),
                        systemImage: "book.closed",
                        description: Text("courses.empty.detail")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                }
                ForEach(summaries) { summary in
                    NavigationLink {
                        ProjectDetailView(viewModel: viewModel, project: summary.project)
                    } label: {
                        CourseSummaryCard(summary: summary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, StudioTheme.pageInset)
            .padding(.vertical, 12)
        }
        .background(StudioTheme.pageBackground.ignoresSafeArea())
        .navigationTitle(Text("courses.title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreate = true
                } label: {
                    Label("courses.create", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    NavigationLink {
                        ProjectArchiveView(viewModel: viewModel)
                    } label: {
                        Label("courses.archive", systemImage: "archivebox")
                    }
                    NavigationLink {
                        TrashView(viewModel: viewModel)
                    } label: {
                        Label("courses.trash", systemImage: "trash")
                    }
                    NavigationLink {
                        ProductHealthView(report: viewModel.productHealth())
                    } label: {
                        Label("nav.product_health", systemImage: "waveform.path.ecg")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("courses.more"))
            }
        }
        .sheet(isPresented: $showingCreate, onDismiss: {
            // The wizard opens only after the create sheet has fully
            // dismissed; stacking sheets in one action drops the second one.
            if let project = pendingWizardProject {
                pendingWizardProject = nil
                createdCourseProject = project
            }
        }) {
            NewCourseSheet { name, area in
                try viewModel.createIdea(name: name, area: area)
            } onCreated: { project in
                pendingWizardProject = project
                showingCreate = false
            }
        }
        .sheet(item: $createdCourseProject) { project in
            CoursePlanWizardView(viewModel: viewModel, project: project)
        }
    }
}

// MARK: - Course summary card

private struct CourseSummaryCard: View {
    let summary: CourseSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: summary.isManualProject ? "square.and.pencil" : "book.closed.fill")
                    .foregroundStyle(StudioTheme.accent)
                Text(summary.project.name)
                    .font(.headline)
                Spacer(minLength: 8)
                if summary.isManualProject {
                    Text("courses.manual_badge")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(StudioTheme.mutedSurface, in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let phase = summary.currentPhase {
                labeledRow(
                    title: String(localized: "courses.phase"),
                    value: phase.title,
                    detail: summary.milestone
                )
            }

            labeledRow(
                title: String(localized: "courses.next_step"),
                value: summary.nextStep ?? String(localized: "courses.no_next_step"),
                detail: nil
            )

            if let record = summary.lastConfirmedRecord {
                labeledRow(
                    title: String(localized: "courses.last_record"),
                    value: record.note,
                    detail: record.endedAt.formatted(date: .abbreviated, time: .omitted)
                )
            } else {
                Label(String(localized: "courses.no_records"), systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if summary.pendingSuggestionCount > 0 {
                Label(
                    String(
                        format: String(localized: "courses.pending_suggestions"),
                        summary.pendingSuggestionCount
                    ),
                    systemImage: "lightbulb.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(StudioTheme.notice)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func labeledRow(title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - New course sheet

/// Creates the project shell for a new course, then hands off to the course
/// plan wizard (spec 6.2). No forced session, no fake record.
private struct NewCourseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let createProject: (String, String) throws -> Project
    let onCreated: (Project) -> Void

    @State private var name = ""
    @State private var area = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "courses.create.name_placeholder"), text: $name)
                    TextField(String(localized: "courses.create.area_placeholder"), text: $area)
                } footer: {
                    Text("courses.create.footer")
                }
            }
            .navigationTitle(Text("courses.create.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("courses.create.cancel")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        do {
                            onCreated(try createProject(name, area))
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        Text("courses.create.next")
                    }
                    .disabled(name.trimmedForJournal.isEmpty)
                }
            }
            .alert(
                String(localized: "courses.create.error_title"),
                isPresented: .constant(errorMessage != nil)
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
