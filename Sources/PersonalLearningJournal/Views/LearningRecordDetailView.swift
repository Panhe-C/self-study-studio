import SwiftUI

/// Confirmed learning-record detail (spec 10): shows the record, its
/// assessment, the confirmed/amended status as real text, and the revision
/// history. Amending appends a revision snapshot and bumps `revision`;
/// it never rewrites plan or Next Step state.
public struct LearningRecordDetailView: View {
    @ObservedObject private var viewModel: JournalViewModel
    private let session: LearningSession
    @State private var isAmending = false
    @State private var errorMessage: String?

    public init(viewModel: JournalViewModel, session: LearningSession) {
        self.viewModel = viewModel
        self.session = session
    }

    private var current: LearningSession {
        viewModel.sessions.first { $0.id == session.id } ?? session
    }

    private var revisions: [LearningRecordRevision] {
        viewModel.learningRecordRevisions(for: session.id)
    }

    public var body: some View {
        Form {
            Section("study_flow.detail.record") {
                Text(current.note)
                LabeledContent(
                    "study_flow.detail.duration",
                    value: "\(current.durationMinutes) min"
                )
                LabeledContent(
                    "study_flow.detail.ended",
                    value: current.endedAt.formatted(date: .abbreviated, time: .shortened)
                )
            }

            if let assessment = current.assessment {
                Section("study_flow.detail.assessment") {
                    LabeledContent(
                        "study_flow.check.progress",
                        value: StudyFlowCopy.progressTitle(assessment.progress)
                    )
                    LabeledContent(
                        "study_flow.check.criteria",
                        value: "\(assessment.completedCriterionIDs.count)"
                    )
                    if let understanding = assessment.understanding {
                        LabeledContent(
                            "study_flow.check.understanding",
                            value: StudyFlowCopy.understandingTitle(understanding)
                        )
                    }
                    if let blocker = assessment.blocker, !blocker.isEmpty {
                        LabeledContent("study_flow.check.blocker", value: blocker)
                    }
                }

                Section("study_flow.detail.status") {
                    // Real text labels so VoiceOver reads the status (spec 16).
                    Label(StudyFlowCopy.confirmedStatusTitle, systemImage: "checkmark.seal")
                        .foregroundStyle(StudioTheme.completed)
                    LabeledContent(
                        "study_flow.detail.confirmed_at",
                        value: assessment.confirmedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    if assessment.revision > 1, let latest = revisions.first {
                        Label(
                            String(
                                format: String(localized: "study_flow.detail.amended_at"),
                                latest.revisedAt.formatted(date: .abbreviated, time: .shortened)
                            ),
                            systemImage: "pencil.and.outline"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if !revisions.isEmpty {
                Section("study_flow.detail.revision_history") {
                    ForEach(revisions) { revision in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                String(
                                    format: String(localized: "study_flow.detail.revision_entry"),
                                    revision.revision,
                                    revision.revisedAt.formatted(date: .abbreviated, time: .shortened)
                                )
                            )
                            .font(.subheadline.weight(.semibold))
                            Text(revision.previousNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            if let previous = revision.previousAssessment {
                                Text(StudyFlowCopy.progressTitle(previous.progress))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if current.assessment != nil {
                Section {
                    Button {
                        isAmending = true
                    } label: {
                        Label("study_flow.detail.amend", systemImage: "pencil")
                    }
                    .accessibilityLabel(Text("study_flow.detail.amend"))
                }
            }
        }
        .navigationTitle(Text("study_flow.detail.title"))
        .sheet(isPresented: $isAmending) {
            AmendLearningRecordSheet(viewModel: viewModel, session: current)
        }
        .alert("study_flow.error.title", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

/// Amend form (spec 10): edits note, progress, completed items are kept as
/// previously recorded, understanding, and blocker. Saving appends a
/// revision snapshot of the previous values first.
private struct AmendLearningRecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: JournalViewModel
    let session: LearningSession
    @State private var note: String
    @State private var progress: CompletionProgress
    @State private var understanding: UnderstandingLevel?
    @State private var blocker: String
    @State private var errorMessage: String?

    init(viewModel: JournalViewModel, session: LearningSession) {
        self.viewModel = viewModel
        self.session = session
        _note = State(initialValue: session.note)
        _progress = State(initialValue: session.assessment?.progress ?? .partial)
        _understanding = State(initialValue: session.assessment?.understanding)
        _blocker = State(initialValue: session.assessment?.blocker ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("study_flow.draft.summary") {
                    TextEditor(text: $note)
                        .frame(minHeight: 100)
                }
                Section("study_flow.check.progress") {
                    Picker("study_flow.check.progress", selection: $progress) {
                        ForEach(CompletionProgress.allCases, id: \.self) { option in
                            Text(StudyFlowCopy.progressTitle(option)).tag(option)
                        }
                    }
                }
                Section("study_flow.check.understanding") {
                    Picker(selection: $understanding) {
                        Text("study_flow.check.understanding.placeholder")
                            .tag(UnderstandingLevel?.none)
                        ForEach(UnderstandingLevel.allCases, id: \.self) { level in
                            Text(StudyFlowCopy.understandingTitle(level))
                                .tag(UnderstandingLevel?.some(level))
                        }
                    } label: {
                        Text("study_flow.check.understanding")
                    }
                }
                Section("study_flow.check.blocker") {
                    TextField("study_flow.check.blocker.placeholder", text: $blocker, axis: .vertical)
                }
            }
            .navigationTitle(Text("study_flow.detail.amend"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { save() }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("study_flow.error.title", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        do {
            _ = try viewModel.amendLearningRecord(
                sessionID: session.id,
                note: note,
                progress: progress,
                completedCriterionIDs: session.assessment?.completedCriterionIDs ?? [],
                understanding: understanding,
                blocker: blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : blocker
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
