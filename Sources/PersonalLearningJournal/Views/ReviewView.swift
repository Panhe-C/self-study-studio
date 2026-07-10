import SwiftUI

public struct ReviewView: View {
    @ObservedObject private var viewModel: JournalViewModel
    private var review: Review
    @State private var facts: [String]
    @State private var patterns: [String]
    @State private var decisions: [String]
    @State private var nextSteps: [UUID: String]
    @State private var notice: ReviewNotice?

    public init(viewModel: JournalViewModel, review: Review) {
        self.viewModel = viewModel
        self.review = review
        _facts = State(initialValue: review.facts)
        _patterns = State(initialValue: review.patterns)
        _decisions = State(initialValue: review.decisions)
        _nextSteps = State(initialValue: review.nextSteps)
    }

    public var body: some View {
        List {
            EditableReviewSection(
                title: "Facts",
                itemName: "Fact",
                items: $facts,
                sourceReferences: currentReview.sourceReferences
            )
            EditableReviewSection(
                title: "Patterns",
                itemName: "Pattern",
                items: $patterns,
                sourceReferences: currentReview.sourceReferences
            )
            EditableReviewSection(
                title: "Decisions",
                itemName: "Decision",
                items: $decisions,
                sourceReferences: currentReview.sourceReferences
            )

            Section("Next Steps") {
                if nextSteps.isEmpty {
                    ContentUnavailableView(
                        "No Next Steps",
                        systemImage: "figure.walk",
                        description: Text("This review did not produce project-specific next steps.")
                    )
                } else {
                    ForEach(nextStepProjectIds, id: \.self) { projectId in
                        TextField(
                            projectName(for: projectId),
                            text: Binding(
                                get: { nextSteps[projectId] ?? "" },
                                set: { nextSteps[projectId] = $0 }
                            ),
                            axis: .vertical
                        )
                    }
                }
            }

            Section("Recommendations") {
                if recommendationProjectIds.isEmpty {
                    Text("No project actions were suggested for this review.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recommendationProjectIds, id: \.self) { projectId in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(projectName(for: projectId))
                                .font(.headline)

                            if let status = currentReview.projectRecommendations[projectId] {
                                Label(
                                    "Suggested status: \(status.rawValue)",
                                    systemImage: "arrow.down.circle"
                                )
                                Button("Apply Status") {
                                    applyRecommendation(for: projectId)
                                }
                            }

                            if let nextStep = currentReview.nextSteps[projectId] {
                                Text("Suggested next: \(nextStep)")
                                    .foregroundStyle(.secondary)
                                Button("Use as Next Step") {
                                    applyNextStep(for: projectId)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Sources") {
                if currentReview.aiSourceSummary.isEmpty {
                    Text("No session or Proof sources were attached.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(currentReview.aiSourceSummary, id: \.self) { source in
                        Label(source, systemImage: "quote.bubble")
                    }
                }
            }
        }
        .navigationTitle("Weekly Review")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
            }
        }
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

    private var nextStepProjectIds: [UUID] {
        nextSteps.keys.sorted { left, right in
            projectName(for: left) < projectName(for: right)
        }
    }

    private var recommendationProjectIds: [UUID] {
        Set(currentReview.projectRecommendations.keys)
            .union(currentReview.nextSteps.keys)
            .sorted { projectName(for: $0) < projectName(for: $1) }
    }

    private func projectName(for projectId: UUID) -> String {
        viewModel.projects.first { $0.id == projectId }?.name ?? "Project"
    }

    private func save() {
        do {
            _ = try viewModel.updateReview(
                reviewId: review.id,
                facts: facts,
                patterns: patterns,
                decisions: decisions,
                nextSteps: nextSteps
            )
            notice = ReviewNotice(title: "Review Saved", message: "Your edits were saved.")
        } catch {
            notice = ReviewNotice(title: "Review Not Saved", message: error.localizedDescription)
        }
    }

    private func applyRecommendation(for projectId: UUID) {
        do {
            try viewModel.applyReviewRecommendation(reviewId: review.id, projectId: projectId)
            notice = ReviewNotice(title: "Status Applied", message: "The project status now follows this review decision.")
        } catch {
            notice = ReviewNotice(title: "Status Not Applied", message: error.localizedDescription)
        }
    }

    private func applyNextStep(for projectId: UUID) {
        do {
            try viewModel.applyReviewNextStep(reviewId: review.id, projectId: projectId)
            notice = ReviewNotice(title: "Next Step Applied", message: "The project now uses this review next step.")
        } catch {
            notice = ReviewNotice(title: "Next Step Not Applied", message: error.localizedDescription)
        }
    }
}

private struct EditableReviewSection: View {
    var title: String
    var itemName: String
    @Binding var items: [String]
    var sourceReferences: [String: [String]]

    var body: some View {
        Section(title) {
            ForEach(items.indices, id: \.self) { index in
                TextField(
                    itemName,
                    text: Binding(
                        get: { items[index] },
                        set: { items[index] = $0 }
                    ),
                    axis: .vertical
                )
                if let sources = sourceReferences[items[index]], !sources.isEmpty {
                    ForEach(sources, id: \.self) { source in
                        Label(source, systemImage: "quote.bubble")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                items.append("")
            } label: {
                Label("Add \(itemName)", systemImage: "plus")
            }
        }
    }
}

private struct ReviewNotice: Identifiable {
    var id = UUID()
    var title: String
    var message: String
}
