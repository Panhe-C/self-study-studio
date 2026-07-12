import SwiftUI

struct CoursePlanDetailView: View {
    @ObservedObject private var viewModel: JournalViewModel
    private let project: Project
    private let plan: CoursePlan
    @State private var showingRevision = false

    init(viewModel: JournalViewModel, project: Project, plan: CoursePlan) {
        self.viewModel = viewModel
        self.project = project
        self.plan = plan
    }

    var body: some View {
        List {
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

            let archived = viewModel.coursePlans(for: project.id).filter { $0.status == .archived || $0.status == .completed }
            if !archived.isEmpty {
                Section("Previous revisions") {
                    ForEach(archived) { revision in
                        LabeledContent("Revision \(revision.revision)", value: revision.status.rawValue.capitalized)
                    }
                }
            }
        }
        .navigationTitle(plan.courseTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingRevision = true
                } label: {
                    Label("Revise Plan", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showingRevision) {
            CoursePlanWizardView(viewModel: viewModel, project: project, revisionSource: plan)
        }
    }
}
