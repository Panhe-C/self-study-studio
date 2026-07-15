import SwiftUI

public struct MigrationReviewView: View {
    private let dryRun: MigrationDryRun
    private let onContinue: () -> Void

    public init(dryRun: MigrationDryRun, onContinue: @escaping () -> Void) {
        self.dryRun = dryRun
        self.onContinue = onContinue
    }

    public var body: some View {
        List {
            Section("Migration review") {
                Text("Review every ambiguous Proof and Practice link before changing your journal.")
                    .foregroundStyle(.secondary)
            }
            Section("Issues") {
                ForEach(Array(dryRun.issues.enumerated()), id: \.offset) { _, issue in
                    Label(label(for: issue), systemImage: "exclamationmark.triangle")
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
