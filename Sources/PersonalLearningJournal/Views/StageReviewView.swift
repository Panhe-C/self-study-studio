import SwiftUI

public struct StageReviewView: View {
    @ObservedObject private var viewModel: JournalViewModel
    private let review: Review
    @State private var decisionKind: ReviewDecisionKind = .continueUnchanged
    @State private var selectedProofID: UUID?
    @State private var acceptedCriteria = ""
    @State private var notice: StageReviewNotice?

    public init(viewModel: JournalViewModel, review: Review) {
        self.viewModel = viewModel
        self.review = review
    }

    public var body: some View {
        List {
            if let project, let phase {
                readinessSection(project: project, phase: phase)
            } else {
                Section("Stage Review") {
                    Label("This review is missing its Project or Phase anchor.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Review Facts") {
                ForEach(currentReview.facts, id: \.self) { fact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fact)
                        ForEach(currentReview.sourceReferences[fact, default: []], id: \.self) { source in
                            Label(source, systemImage: "link")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if currentReview.status == .draft {
                Section("Decision") {
                    Picker("Decision", selection: $decisionKind) {
                        ForEach(stageDecisionKinds, id: \.self) { kind in
                            Text(title(for: kind)).tag(kind)
                        }
                    }
                    .accessibilityLabel("Stage Review decision")

                    if decisionKind == .advancePhase {
                        proofPicker
                        TextField("What does this Proof satisfy?", text: $acceptedCriteria, axis: .vertical)
                            .accessibilityLabel("Qualifying Proof acceptance criteria")
                        if selectedProofID == nil || acceptedCriteria.trimmedForJournal.isEmpty {
                            Label("Advance is blocked until you select qualifying Proof and state the satisfied criterion.", systemImage: "lock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Advance blocked: select proof and acceptance criterion")
                        }
                    }

                    Button("Publish Stage Review", action: publish)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canPublish)
                        .accessibilityHint(currentReview.status == .draft ? "Publishes the decision atomically" : "Already published")
                }
            } else {
                Section("Published History") {
                    Label(
                        "Published \(currentReview.publishedAt?.formatted(date: .abbreviated, time: .shortened) ?? currentReview.updatedAt.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "checkmark.seal"
                    )
                    Text("Decision and any accepted Proof remain linked in Journal history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(currentReview.referencedProofRevisionIds, id: \.self) { revisionID in
                        Label("Proof revision \(revisionID.uuidString.prefix(8))", systemImage: "doc.text.magnifyingglass")
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Stage Review")
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var currentReview: Review {
        viewModel.reviews.first { $0.id == review.id } ?? review
    }

    private var project: Project? {
        guard let projectID = currentReview.projectId else { return nil }
        return viewModel.projects.first { $0.id == projectID }
    }

    private var phase: PlanPhase? {
        guard let phaseID = currentReview.phaseId else { return nil }
        return viewModel.planPhases.first { $0.id == phaseID }
    }

    private var qualifyingProofs: [Proof] {
        guard let projectID = currentReview.projectId else { return [] }
        return viewModel.proofsForProject(projectID)
            .filter(\.qualifies)
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    private var stageDecisionKinds: [ReviewDecisionKind] {
        [.continueUnchanged, .advancePhase, .extendPhase, .revisePhase, .pause, .abandon]
    }

    private var canPublish: Bool {
        guard currentReview.status == .draft else { return false }
        guard decisionKind == .advancePhase else { return true }
        return selectedProofID != nil && !acceptedCriteria.trimmedForJournal.isEmpty
    }

    @ViewBuilder
    private func readinessSection(project: Project, phase: PlanPhase) -> some View {
        Section("Readiness") {
            let readiness = try? viewModel.stageReviewReadiness(
                projectID: project.id,
                phaseID: phase.id,
                at: Date(),
                requested: currentReview.status == .draft
            )
            Label(
                readiness?.isReady == true ? "Ready for explicit review" : "Not ready",
                systemImage: readiness?.isReady == true ? "checkmark.circle" : "clock"
            )
            Text(readiness?.explanation ?? "Readiness could not be derived from the current Journal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Phase: \(phase.title) · \(project.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var proofPicker: some View {
        Picker("Qualifying Proof", selection: $selectedProofID) {
            Text("Select Proof").tag(UUID?.none)
            ForEach(qualifyingProofs) { proof in
                Text(proof.title).tag(Optional(proof.id))
            }
        }
        .accessibilityLabel("Qualifying Proof evidence")
    }

    private func publish() {
        guard let projectID = currentReview.projectId, let phaseID = currentReview.phaseId else { return }
        let decision = ReviewDecision(
            reviewId: currentReview.id,
            projectId: projectID,
            kind: decisionKind,
            phaseId: phaseID,
            decidedAt: Date()
        )
        do {
            _ = try viewModel.publishStageReview(
                reviewID: currentReview.id,
                decision: decision,
                qualifyingProofID: selectedProofID,
                acceptedCriteria: [acceptedCriteria]
            )
            notice = StageReviewNotice(title: "Stage Review Published", message: "The review, decision, and any Proof linkage were committed together.")
        } catch {
            notice = StageReviewNotice(title: "Publish Blocked", message: error.localizedDescription)
        }
    }

    private func title(for kind: ReviewDecisionKind) -> String {
        switch kind {
        case .continueUnchanged: "Continue unchanged"
        case .advancePhase: "Advance phase"
        case .extendPhase: "Extend phase"
        case .revisePhase: "Revise plan"
        case .pause: "Pause project"
        case .abandon, .archive: "Abandon project"
        case .changeNextStep, .reviseContract, .changeFrequency, .complete: kind.rawValue
        }
    }
}

private struct StageReviewNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
