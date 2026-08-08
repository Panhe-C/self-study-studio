import SwiftUI

/// Explicit B2 survivor selection. The migration never guesses which active
/// revision wins when legacy data contains more than one active plan.
public struct PlanRevisionMigrationReviewView: View {
    private let snapshot: JournalSnapshot
    private let dryRun: PlanRevisionMigrationDryRun
    private let onContinue: ([UUID: UUID]) -> Void
    @State private var survivors: [UUID: UUID] = [:]

    public init(
        snapshot: JournalSnapshot,
        dryRun: PlanRevisionMigrationDryRun,
        onContinue: @escaping ([UUID: UUID]) -> Void
    ) {
        self.snapshot = snapshot
        self.dryRun = dryRun
        self.onContinue = onContinue
    }

    public var body: some View {
        List {
            Section("Choose the surviving Learning Plan revision") {
                Text("Multiple active revisions were found. Select one per project; all other revisions remain readable as superseded history.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(dryRun.issues, id: \.self) { issue in
                if case let .multipleActivePlans(projectID) = issue {
                    let project = snapshot.projects.first { $0.id == projectID }
                    let plans = snapshot.coursePlans
                        .filter { $0.projectId == projectID && $0.status == .active }
                        .sorted { $0.revision > $1.revision }
                    Section(project?.name ?? "Project") {
                        Picker("Surviving revision", selection: selection(for: projectID)) {
                            Text("Choose a revision").tag(UUID?.none)
                            ForEach(plans) { plan in
                                Text("Revision \(plan.revision): \(plan.courseTitle)")
                                    .tag(Optional(plan.id))
                            }
                        }
                    }
                }
            }

            Button("Continue with selected revisions") {
                onContinue(survivors)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasCompleteSelection)
        }
        .navigationTitle("Learning Plan Migration")
    }

    private func selection(for projectID: UUID) -> Binding<UUID?> {
        Binding(
            get: { survivors[projectID] },
            set: { value in
                if let value {
                    survivors[projectID] = value
                } else {
                    survivors.removeValue(forKey: projectID)
                }
            }
        )
    }

    private var hasCompleteSelection: Bool {
        let projectIDs = dryRun.issues.compactMap { issue -> UUID? in
            guard case let .multipleActivePlans(projectID) = issue else { return nil }
            return projectID
        }
        return projectIDs.allSatisfy { survivors[$0] != nil }
    }
}
