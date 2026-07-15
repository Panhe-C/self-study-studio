import SwiftUI

public struct TimerSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: JournalViewModel
    private let project: Project
    private let plannedSession: PlannedSession?
    @State private var runStartedAt = Date()
    @State private var activeElapsedSeconds: TimeInterval = 0
    @State private var isRunning = true
    @State private var hasEnded = false
    @State private var note = ""
    @State private var nextStep = ""
    @State private var proofSession: LearningSession?
    @State private var errorMessage: String?

    public init(
        viewModel: JournalViewModel,
        project: Project,
        plannedSession: PlannedSession? = nil
    ) {
        self.viewModel = viewModel
        self.project = project
        self.plannedSession = plannedSession
        _nextStep = State(initialValue: "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(project.name) {
                    if let plannedSession {
                        Text(plannedSession.title)
                            .font(.headline)
                        if let expectedProof = plannedSession.expectedProof, !expectedProof.isEmpty {
                            Label(expectedProof, systemImage: "paperclip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(statusText)
                        .font(.headline)

                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        LabeledContent("Active Time", value: "\(activeDurationMinutes) min")
                    }

                    Button {
                        togglePause()
                    } label: {
                        Label(isRunning ? "Pause" : "Resume", systemImage: isRunning ? "pause.circle" : "play.circle")
                    }
                    .disabled(hasEnded)

                    Button {
                        endTimer()
                    } label: {
                        Label("End", systemImage: "stop.circle")
                    }
                    .disabled(hasEnded)

                    Button(role: .destructive) {
                        dismiss()
                    } label: {
                        Label("Discard", systemImage: "xmark.circle")
                    }
                }

                Section("Finish") {
                    TextField("One sentence", text: $note, axis: .vertical)
                    LabeledContent("Current Next Step", value: project.currentNextStep)
                    TextField("Replacement (optional)", text: $nextStep, axis: .vertical)
                }
            }
            .navigationTitle("Timer")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(addProof: false)
                    }
                    .disabled(note.trimmedForJournal.isEmpty)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        save(addProof: true)
                    } label: {
                        Label("Save & Add Proof", systemImage: "paperclip.badge.plus")
                    }
                    .disabled(note.trimmedForJournal.isEmpty)
                }
            }
            .sheet(item: $proofSession) { session in
                AddProofView(viewModel: viewModel, project: project, session: session)
                    .onDisappear {
                        dismiss()
                    }
            }
            .alert("Could not save", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var statusText: String {
        if hasEnded {
            "Ended"
        } else if isRunning {
            "Running"
        } else {
            "Paused"
        }
    }

    private var currentActiveSeconds: TimeInterval {
        activeElapsedSeconds + (isRunning && !hasEnded ? Date().timeIntervalSince(runStartedAt) : 0)
    }

    private var activeDurationMinutes: Int {
        max(1, Int(currentActiveSeconds / 60))
    }

    private func togglePause() {
        if isRunning {
            activeElapsedSeconds += Date().timeIntervalSince(runStartedAt)
            isRunning = false
        } else {
            runStartedAt = Date()
            isRunning = true
        }
    }

    private func endTimer() {
        if isRunning {
            activeElapsedSeconds += Date().timeIntervalSince(runStartedAt)
        }
        isRunning = false
        hasEnded = true
    }

    private func save(addProof: Bool) {
        do {
            if !hasEnded {
                endTimer()
            }
            let endedAt = Date()
            let startedAt = endedAt.addingTimeInterval(-TimeInterval(activeDurationMinutes * 60))
            let session = try viewModel.saveTimerSession(
                projectId: project.id,
                actionType: plannedSession?.actionType ?? project.lastActionType,
                startedAt: startedAt,
                endedAt: endedAt,
                note: note,
                nextStep: QuickLogView.confirmedNextStep(
                    current: project.currentNextStep,
                    replacement: nextStep
                ),
                plannedSessionId: plannedSession?.id
            )
            if addProof {
                proofSession = session
            } else {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
