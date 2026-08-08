import SwiftUI

public struct MigrationReviewView: View {
    private let dryRun: MigrationDryRun
    private let onContinue: () -> Void
    private let onStatusResolution: ((UUID, ProjectStatusMigrationResolution) -> Void)?
    private let onProofResolution: ((UUID, ProofMigrationResolution) -> Void)?
    private let onPracticeResolution: ((UUID, PracticeMigrationResolution) -> Void)?
    private let onAttachEvidence: ((UUID) -> Void)?
    private let onConvertToSessionNote: ((UUID) -> Void)?
    private let onMoveProofToTrash: ((UUID) -> Void)?
    @State private var statusResolutions: [UUID: ProjectStatusMigrationResolution] = [:]
    @State private var proofResolutions: [UUID: ProofMigrationResolution] = [:]
    @State private var practiceResolutions: [UUID: PracticeMigrationResolution] = [:]

    public init(
        dryRun: MigrationDryRun,
        onContinue: @escaping () -> Void,
        onStatusResolution: ((UUID, ProjectStatusMigrationResolution) -> Void)? = nil,
        onProofResolution: ((UUID, ProofMigrationResolution) -> Void)? = nil,
        onPracticeResolution: ((UUID, PracticeMigrationResolution) -> Void)? = nil,
        onAttachEvidence: ((UUID) -> Void)? = nil,
        onConvertToSessionNote: ((UUID) -> Void)? = nil,
        onMoveProofToTrash: ((UUID) -> Void)? = nil
    ) {
        self.dryRun = dryRun
        self.onContinue = onContinue
        self.onStatusResolution = onStatusResolution
        self.onProofResolution = onProofResolution
        self.onPracticeResolution = onPracticeResolution
        self.onAttachEvidence = onAttachEvidence
        self.onConvertToSessionNote = onConvertToSessionNote
        self.onMoveProofToTrash = onMoveProofToTrash
    }

    public var body: some View {
        List {
            Section("migration.title") {
                Text("Review every ambiguous Proof and Practice link before changing your journal.")
                    .foregroundStyle(.secondary)
            }
            Section("Issues") {
                ForEach(Array(dryRun.issues.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(label(for: issue), systemImage: "exclamationmark.triangle")
                        if case let .proofNeedsEvidence(proofID) = issue {
                            HStack {
                                Button("migration.attach_evidence") { onAttachEvidence?(proofID) }
                                    .disabled(onAttachEvidence == nil)
                                Button("migration.convert_note") { onConvertToSessionNote?(proofID) }
                                    .disabled(onConvertToSessionNote == nil)
                                Button("Trash", role: .destructive) { onMoveProofToTrash?(proofID) }
                                    .disabled(onMoveProofToTrash == nil)
                            }
                            .buttonStyle(.borderless)
                            Button("Keep as needs evidence") {
                                proofResolutions[proofID] = .keepNeedsEvidence
                                onProofResolution?(proofID, .keepNeedsEvidence)
                            }
                            .buttonStyle(.bordered)
                            .tint(proofResolutions[proofID] == .keepNeedsEvidence ? StudioTheme.accent : nil)
                        }
                        if case let .practiceNeedsProject(routineID) = issue {
                            Button("Keep routine unlinked") {
                                practiceResolutions[routineID] = .keepUnlinked
                                onPracticeResolution?(routineID, .keepUnlinked)
                            }
                            .buttonStyle(.bordered)
                            .tint(practiceResolutions[routineID] == .keepUnlinked ? StudioTheme.accent : nil)
                        }
                        if case let .projectNeedsStatusResolution(projectID) = issue {
                            statusDecisionPicker(for: projectID)
                        }
                        if case let .trashNeedsStatusResolution(projectID) = issue {
                            statusDecisionPicker(for: projectID)
                        }
                    }
                }
            }
            Button("Continue with resolutions", action: onContinue)
                .disabled(hasUnresolvedDecisions)
        }
        .navigationTitle("Safe Migration")
    }

    private func label(for issue: MigrationIssue) -> String {
        switch issue {
        case .proofNeedsEvidence: "Proof needs inspectable evidence"
        case .practiceNeedsProject: "Practice needs a project decision"
        case .projectNeedsSetup: "Project needs a commitment"
        case .projectNeedsStatusResolution: "Archived project needs a status decision"
        case .trashNeedsStatusResolution: "Trashed project needs a prior status decision"
        }
    }

    private var hasUnresolvedDecisions: Bool {
        dryRun.issues.contains { issue in
            switch issue {
            case let .proofNeedsEvidence(id):
                return proofResolutions[id] == nil
            case let .practiceNeedsProject(id):
                return practiceResolutions[id] == nil
            case let .projectNeedsStatusResolution(id), let .trashNeedsStatusResolution(id):
                return statusResolutions[id] == nil
            default:
                return false
            }
        }
    }

    @ViewBuilder
    private func statusDecisionPicker(for projectID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose the canonical lifecycle status. No status is inferred from evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                ForEach(ProjectStatusMigrationResolution.allCases, id: \.self) { resolution in
                    Button(resolution.title) {
                        statusResolutions[projectID] = resolution
                        onStatusResolution?(projectID, resolution)
                    }
                    .buttonStyle(.bordered)
                    .tint(statusResolutions[projectID] == resolution ? StudioTheme.accent : nil)
                }
            }
        }
    }
}

private extension ProjectStatusMigrationResolution {
    var title: String {
        switch self {
        case .pause: "Paused"
        case .complete: "Completed"
        case .abandon: "Abandoned"
        }
    }
}
