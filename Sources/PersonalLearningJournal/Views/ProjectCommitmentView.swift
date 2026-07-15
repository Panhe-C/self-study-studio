import SwiftUI

public struct ProjectCommitmentView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: JournalViewModel
    private let project: Project
    @State private var goal: String
    @State private var nextStep: String
    @State private var triggerMode: TriggerMode = .interval
    @State private var intervalDays = 7
    @State private var milestone = ""
    @State private var artifactType: ProofType = .text
    @State private var acceptanceCriteria = ""
    @State private var allowBudgetOverride = false
    @State private var errorMessage: String?

    public init(viewModel: JournalViewModel, project: Project) {
        self.viewModel = viewModel
        self.project = project
        _goal = State(initialValue: project.goal)
        _nextStep = State(initialValue: project.currentNextStep)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Commitment") {
                    TextField("Goal", text: $goal, axis: .vertical)
                    TextField("One canonical Next Step", text: $nextStep, axis: .vertical)
                }
                Section("Evidence Contract") {
                    Picker("Trigger", selection: $triggerMode) {
                        Text("Interval").tag(TriggerMode.interval)
                        Text("Milestone").tag(TriggerMode.milestone)
                    }
                    if triggerMode == .interval {
                        Stepper("Every \(intervalDays) days", value: $intervalDays, in: 1...90)
                    } else {
                        TextField("Milestone", text: $milestone)
                    }
                    Picker("Artifact", selection: $artifactType) {
                        ForEach(ProofType.allCases, id: \.self) { type in
                            Text(type.rawValue.capitalized).tag(type)
                        }
                    }
                    TextField("Acceptance criteria", text: $acceptanceCriteria, axis: .vertical)
                }
                Section {
                    Toggle("Allow more than three active projects", isOn: $allowBudgetOverride)
                } footer: {
                    Text("Only active projects with a complete commitment count toward the attention budget.")
                }
            }
            .navigationTitle("Activate Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Activate", action: activate)
                }
            }
            .alert("Could not activate", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func activate() {
        do {
            let trigger: EvidenceContractTrigger = triggerMode == .interval
                ? .interval(days: intervalDays)
                : .milestone(milestone)
            let timestamp = Date()
            let contract = try EvidenceContract(
                projectId: project.id,
                trigger: trigger,
                expectedArtifact: artifactType,
                acceptanceCriteria: acceptanceCriteria,
                startsAt: timestamp,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            _ = try viewModel.activateProject(
                projectId: project.id,
                goal: goal,
                nextStep: nextStep,
                contract: contract,
                allowAttentionBudgetOverride: allowBudgetOverride
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum TriggerMode: Hashable {
    case interval
    case milestone
}
