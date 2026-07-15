import SwiftUI

public struct MigrationReviewView: View {
    private let dryRun: MigrationDryRun
    private let onContinue: () -> Void
    private let onAttachEvidence: ((UUID) -> Void)?
    private let onConvertToSessionNote: ((UUID) -> Void)?
    private let onMoveProofToTrash: ((UUID) -> Void)?

    public init(
        dryRun: MigrationDryRun,
        onContinue: @escaping () -> Void,
        onAttachEvidence: ((UUID) -> Void)? = nil,
        onConvertToSessionNote: ((UUID) -> Void)? = nil,
        onMoveProofToTrash: ((UUID) -> Void)? = nil
    ) {
        self.dryRun = dryRun
        self.onContinue = onContinue
        self.onAttachEvidence = onAttachEvidence
        self.onConvertToSessionNote = onConvertToSessionNote
        self.onMoveProofToTrash = onMoveProofToTrash
    }

    public var body: some View {
        List {
            Section("Migration review") {
                Text("Review every ambiguous Proof and Practice link before changing your journal.")
                    .foregroundStyle(.secondary)
            }
            Section("Issues") {
                ForEach(Array(dryRun.issues.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(label(for: issue), systemImage: "exclamationmark.triangle")
                        if case let .proofNeedsEvidence(proofID) = issue {
                            HStack {
                                Button("Attach") { onAttachEvidence?(proofID) }
                                    .disabled(onAttachEvidence == nil)
                                Button("Make Session Note") { onConvertToSessionNote?(proofID) }
                                    .disabled(onConvertToSessionNote == nil)
                                Button("Trash", role: .destructive) { onMoveProofToTrash?(proofID) }
                                    .disabled(onMoveProofToTrash == nil)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Button("Continue with resolutions", action: onContinue)
        }
        .navigationTitle("Safe Migration")
    }

    private func label(for issue: MigrationIssue) -> String {
        switch issue {
        case .proofNeedsEvidence: "Proof needs inspectable evidence"
        case .practiceNeedsProject: "Practice needs a project decision"
        case .projectNeedsSetup: "Project needs a commitment"
        }
    }
}
