import SwiftUI

public struct QuickLogView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: JournalViewModel
    private let project: Project
    private let plannedSession: PlannedSession?
    @State private var actionType: ActionType
    @State private var durationMinutes: Int
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
        _actionType = State(initialValue: plannedSession?.actionType ?? project.lastActionType)
        _durationMinutes = State(initialValue: plannedSession?.durationMinutes ?? project.defaultDurationMinutes)
        _nextStep = State(initialValue: project.currentNextStep)
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
                    Picker("Action", selection: $actionType) {
                        ForEach(ActionType.allCases, id: \.self) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }

                    Picker("Duration", selection: $durationMinutes) {
                        ForEach([15, 30, 45, 60], id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 1...480, step: 5)
                    TextField("One sentence", text: $note, axis: .vertical)
                    TextField("Next Step", text: $nextStep, axis: .vertical)
                }
            }
            .navigationTitle("Quick Log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(addProof: false)
                    }
                    .disabled(!Self.canSave(note: note))
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        save(addProof: true)
                    } label: {
                        Label("Save & Add Proof", systemImage: "paperclip.badge.plus")
                    }
                    .disabled(!Self.canSave(note: note))
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

    static func canSave(note: String) -> Bool {
        !note.trimmedForJournal.isEmpty
    }

    private func save(addProof: Bool) {
        do {
            let session = try viewModel.quickLog(
                projectId: project.id,
                actionType: actionType,
                durationMinutes: durationMinutes,
                note: note,
                nextStep: nextStep,
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
