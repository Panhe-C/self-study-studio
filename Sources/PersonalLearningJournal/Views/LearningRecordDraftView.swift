import SwiftUI

/// Editable learning-record draft (spec 9.3): the user reviews and edits the
/// AI/rule-based draft, then confirms, returns to the check, saves for
/// later, or discards (with confirmation). Nothing is a journal fact until
/// 确认记录 succeeds.
public struct LearningRecordDraftView: View {
    @ObservedObject var controller: StudyFlowController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var summary: String
    @State private var result: String
    @State private var blockers: String
    @State private var suggestedNextStep: String
    @State private var showingDiscardConfirmation = false

    public init(controller: StudyFlowController) {
        self.controller = controller
        let draft = controller.currentCapture?.recordDraft
        _summary = State(initialValue: draft?.summary ?? "")
        _result = State(initialValue: draft?.result ?? "")
        _blockers = State(initialValue: draft?.blockers ?? "")
        _suggestedNextStep = State(initialValue: draft?.suggestedNextStep ?? "")
    }

    private var storedDraft: LearningRecordDraft? {
        controller.currentCapture?.recordDraft
    }

    private var prefersVerticalLayout: Bool {
        StudyFlowViewState.prefersVerticalLayout(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    private var editedDraft: LearningRecordDraft {
        LearningRecordDraft(
            summary: summary,
            result: result,
            blockers: blockers,
            suggestedNextStep: suggestedNextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : suggestedNextStep,
            adjustmentSignal: storedDraft?.adjustmentSignal ?? .none,
            rationale: storedDraft?.rationale,
            source: storedDraft?.source ?? .ruleBased
        )
    }

    public var body: some View {
        Form {
            if let draft = storedDraft {
                Section {
                    Text(StudyFlowCopy.draftSourceTitle(draft.source))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(StudyFlowCopy.draftSourceTitle(draft.source)))
                    if draft.adjustmentSignal != .none {
                        Label(
                            StudyFlowCopy.adjustmentSignalTitle(draft.adjustmentSignal),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let rationale = draft.rationale, !rationale.isEmpty {
                            Text(rationale)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("study_flow.draft.summary") {
                    TextEditor(text: $summary)
                        .frame(minHeight: 100)
                }

                Section("study_flow.draft.result") {
                    TextField("study_flow.draft.result.placeholder", text: $result, axis: .vertical)
                }

                Section("study_flow.draft.blockers") {
                    TextField("study_flow.draft.blockers.placeholder", text: $blockers, axis: .vertical)
                }

                Section("study_flow.draft.next_step") {
                    TextField("study_flow.draft.next_step.placeholder", text: $suggestedNextStep, axis: .vertical)
                }

                Section {
                    if prefersVerticalLayout {
                        VStack(spacing: 10) {
                            confirmButton
                            backButton
                            laterButton
                            discardButton
                        }
                    } else {
                        confirmButton
                        backButton
                        laterButton
                        discardButton
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text("study_flow.draft.title"))
        .confirmationDialog(
            Text("study_flow.draft.discard"),
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("study_flow.discard.confirm", role: .destructive) {
                controller.discard()
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("study_flow.discard.message")
        }
    }

    private var confirmButton: some View {
        Button {
            controller.confirm(editedDraft: editedDraft)
        } label: {
            Text("study_flow.draft.confirm")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(StudioTheme.accent)
        .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(Text("study_flow.draft.confirm"))
    }

    private var backButton: some View {
        Button {
            controller.backToCheck()
        } label: {
            Text("study_flow.draft.back")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("study_flow.draft.back"))
    }

    private var laterButton: some View {
        Button {
            controller.saveForLater(editedDraft: editedDraft)
        } label: {
            Text("study_flow.draft.later")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("study_flow.draft.later"))
    }

    private var discardButton: some View {
        Button(role: .destructive) {
            showingDiscardConfirmation = true
        } label: {
            Text("study_flow.draft.discard")
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(Text("study_flow.draft.discard"))
    }
}
