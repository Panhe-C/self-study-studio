import SwiftUI

struct CoursePlanDetailView: View {
    @ObservedObject private var viewModel: JournalViewModel
    private let project: Project
    private let plan: LearningPlan
    @State private var showingRevision = false
    @State private var proposedNextStep = ""
    @State private var errorMessage: String?

    init(viewModel: JournalViewModel, project: Project, plan: LearningPlan) {
        self.viewModel = viewModel
        self.project = project
        self.plan = plan
    }

    var body: some View {
        List {
            if let proposal = viewModel.pendingCanonicalNextStepProposal,
               proposal.projectId == project.id {
                Section("Canonical Next Step proposal") {
                    Text(proposal.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Next Step", text: $proposedNextStep)
                    Button("Confirm Next Step") {
                        do {
                            _ = try viewModel.confirmCanonicalNextStep(
                                proposal,
                                title: proposedNextStep
                            )
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(proposedNextStep.trimmedForJournal.isEmpty)
                }
            }

            Section("Revision \(plan.revision)") {
                LabeledContent("Status", value: plan.status.rawValue.capitalized)
                LabeledContent("Weekly budget", value: "\(plan.weeklyBudgetMinutes) min")
                LabeledContent("Start", value: plan.startsOn.formatted(date: .abbreviated, time: .omitted))
                if let deadline = plan.deadline {
                    LabeledContent("Deadline", value: deadline.formatted(date: .abbreviated, time: .omitted))
                }
                Text(plan.summary).foregroundStyle(.secondary)
            }

            Section("Phases") {
                ForEach(viewModel.phases(for: plan.id)) { phase in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(phase.title).font(.headline)
                        Text(phase.objective).foregroundStyle(.secondary)
                        Label(phase.expectedProof, systemImage: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(phase.targetStart.formatted(date: .abbreviated, time: .omitted)) - \(phase.targetEnd.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            let revisionRoutines = viewModel.practiceRoutineHistory.filter {
                $0.planRevisionID == plan.revisionID
            }
            if !revisionRoutines.isEmpty {
                Section("Practice routines in this revision") {
                    ForEach(revisionRoutines) { routine in
                        HStack {
                            Label(routine.name, systemImage: routine.symbolName)
                            Spacer()
                            Text("\(routine.targetMinutes) min")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if routine.isStructuralLocked {
                            Text("Structure locked after publication")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Planned sessions") {
                ForEach(viewModel.plannedSessions(for: plan.id)) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(session.title).font(.headline)
                            Spacer()
                            Text(session.status.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(session.durationMinutes) min · \(session.actionType.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let proof = session.expectedProof, !proof.isEmpty {
                            Label(proof, systemImage: "paperclip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let sessionID = session.completedSessionId,
                           let completed = viewModel.sessions.first(where: { $0.id == sessionID }) {
                            Text("Completed: \(completed.note)")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            let superseded = viewModel.supersededLearningPlans(for: project.id)
            if !superseded.isEmpty {
                Section("Superseded learning-plan revisions") {
                    ForEach(superseded) { revision in
                        NavigationLink {
                            CoursePlanDetailView(
                                viewModel: viewModel,
                                project: project,
                                plan: revision
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledContent(
                                    "Revision \(revision.revision)",
                                    value: revision.status.rawValue.capitalized
                                )
                                Text(revision.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Open phases, planned sessions, and linked proof")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            let revisionSessionIDs = Set(viewModel.plannedSessions(for: plan.id).compactMap(\.completedSessionId))
            let linkedProofs = viewModel.proofs.filter {
                $0.projectId == project.id && $0.sessionId.map(revisionSessionIDs.contains) == true
            }
            if !linkedProofs.isEmpty {
                Section("Proof linked to this Learning Plan revision") {
                    ForEach(linkedProofs) { proof in
                        NavigationLink {
                            ProofDetailView(
                                viewModel: viewModel,
                                proof: proof,
                                projectName: project.name,
                                sessionSummary: proof.sessionId
                                    .flatMap { id in viewModel.sessions.first(where: { $0.id == id })?.note }
                                    ?? "Linked learning session"
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(proof.title).font(.headline)
                                Text(proof.statement)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(plan.courseTitle)
        .onAppear {
            if let proposal = viewModel.pendingCanonicalNextStepProposal,
               proposal.projectId == project.id {
                proposedNextStep = proposal.title
            }
        }
        .onChange(of: viewModel.pendingCanonicalNextStepProposal) { _, proposal in
            if proposal?.projectId == project.id {
                proposedNextStep = proposal?.title ?? ""
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingRevision = true
                } label: {
                    Label("Adjust Plan", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showingRevision) {
            CoursePlanWizardView(viewModel: viewModel, project: project, revisionSource: plan)
        }
        .alert("Could not update Next Step", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
