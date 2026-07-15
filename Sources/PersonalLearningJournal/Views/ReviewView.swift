import SwiftUI

public struct ReviewView: View {
    @ObservedObject private var viewModel: JournalViewModel
    private let review: Review
    @State private var selectedProjectID: UUID?
    @State private var decisionKind: ReviewDecisionKind = .continueUnchanged
    @State private var replacementNextStep = ""
    @State private var capstoneProofID: UUID?
    @State private var notice: ReviewNotice?

    public init(viewModel: JournalViewModel, review: Review) {
        self.viewModel = viewModel
        self.review = review
        let candidates = Set(review.projectRecommendations.keys).union(review.nextSteps.keys)
        _selectedProjectID = State(initialValue: candidates.sorted { $0.uuidString < $1.uuidString }.first)
    }

    public var body: some View {
        List {
            sourcedSection(title: "Facts", items: currentReview.facts)
            sourcedSection(title: "Patterns", items: currentReview.patterns)

            Section("Confirm one decision") {
                Picker("Project", selection: $selectedProjectID) {
                    Text("Select a project").tag(UUID?.none)
                    ForEach(candidateProjects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                Picker("Decision", selection: $decisionKind) {
                    ForEach(ReviewDecisionKind.allCases, id: \.self) { kind in
                        Text(title(for: kind)).tag(kind)
                    }
                }
                if decisionKind == .changeNextStep {
                    TextField("Replacement Next Step", text: $replacementNextStep, axis: .vertical)
                }
                if decisionKind == .complete {
                    Picker("Capstone Proof", selection: $capstoneProofID) {
                        Text("Select qualifying Proof").tag(UUID?.none)
                        ForEach(qualifyingProofs) { proof in
                            Text(proof.title).tag(Optional(proof.id))
                        }
                    }
                }
                Button("Confirm Decision", action: confirmDecision)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedProjectID == nil)
            }

            Section("Suggestions") {
                ForEach(candidateProjects) { project in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name).font(.headline)
                        if let status = currentReview.projectRecommendations[project.id] {
                            Text("Suggested status: \(status.rawValue)")
                        }
                        if let step = currentReview.nextSteps[project.id] {
                            Text("Suggested Next Step: \(step)")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Section("Sources") {
                if currentReview.aiSourceSummary.isEmpty {
                    Text("No source summaries attached.").foregroundStyle(.secondary)
                } else {
                    ForEach(currentReview.aiSourceSummary, id: \.self) { source in
                        Label(source, systemImage: "quote.bubble")
                    }
                }
            }
        }
        .navigationTitle("Weekly Review")
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var currentReview: Review {
        viewModel.reviews.first { $0.id == review.id } ?? review
    }

    private var candidateProjects: [Project] {
        let ids = Set(currentReview.projectRecommendations.keys)
            .union(currentReview.nextSteps.keys)
        let explicit = viewModel.projects.filter { ids.contains($0.id) }
        return explicit.isEmpty
            ? viewModel.projects.filter { $0.deletedAt == nil && $0.status != .trash }
            : explicit
    }

    private var selectedProject: Project? {
        guard let selectedProjectID else { return nil }
        return viewModel.projects.first { $0.id == selectedProjectID }
    }

    private var qualifyingProofs: [Proof] {
        guard let selectedProjectID else { return [] }
        return viewModel.proofsForProject(selectedProjectID).filter(\.qualifies)
    }

    private func sourcedSection(title: String, items: [String]) -> some View {
        Section(title) {
            ForEach(items, id: \.self) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item)
                    ForEach(currentReview.sourceReferences[item, default: []], id: \.self) { source in
                        Label(source, systemImage: "quote.bubble")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func confirmDecision() {
        guard let project = selectedProject else { return }
        let decision = ReviewDecision(
            reviewId: review.id,
            projectId: project.id,
            kind: decisionKind,
            nextStep: decisionKind == .changeNextStep ? replacementNextStep : nil,
            contractId: decisionKind == .reviseContract || decisionKind == .changeFrequency
                ? project.activeEvidenceContractId
                : nil,
            capstoneProofId: decisionKind == .complete ? capstoneProofID : nil
        )
        do {
            _ = try viewModel.completeReview(reviewId: review.id, decision: decision)
            notice = ReviewNotice(title: "Decision Confirmed", message: "The project was updated atomically.")
        } catch {
            notice = ReviewNotice(title: "Decision Not Confirmed", message: error.localizedDescription)
        }
    }

    private func title(for kind: ReviewDecisionKind) -> String {
        switch kind {
        case .continueUnchanged: "Continue unchanged"
        case .changeNextStep: "Change Next Step"
        case .reviseContract: "Revise Contract"
        case .changeFrequency: "Change frequency"
        case .pause: "Pause"
        case .archive: "Archive"
        case .complete: "Complete"
        }
    }
}

private struct ReviewNotice: Identifiable {
    var id = UUID()
    var title: String
    var message: String
}
