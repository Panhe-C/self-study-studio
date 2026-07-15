import SwiftUI

public struct TrashView: View {
    @ObservedObject private var viewModel: JournalViewModel
    private let archiveService: JournalArchiveService
    private let onPermanentDelete: ((TrashPurgeImpact) -> Void)?
    @State private var pendingImpact: TrashPurgeImpact?
    @State private var errorMessage: String?

    public init(
        viewModel: JournalViewModel,
        archiveService: JournalArchiveService = JournalArchiveService(),
        onPermanentDelete: ((TrashPurgeImpact) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.archiveService = archiveService
        self.onPermanentDelete = onPermanentDelete
    }

    public var body: some View {
        List {
            Section {
                Text("trash.retention_notice")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(trashedProjects) { project in
                let impact = archiveService.purgeImpact(projectID: project.id, snapshot: viewModel.snapshot)
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.name).font(.headline)
                    Text("\(impact.sessionCount) sessions · \(impact.proofCount) proofs · \(impact.attachmentPaths.count) attachments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("trash.restore") { restore(project) }
                        Spacer()
                        Button("trash.delete_permanently", role: .destructive) { pendingImpact = impact }
                            .disabled(onPermanentDelete == nil)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("nav.trash")
        .overlay {
            if trashedProjects.isEmpty { ContentUnavailableView("trash.empty", systemImage: "trash") }
        }
        .alert("Delete permanently?", isPresented: Binding(
            get: { pendingImpact != nil },
            set: { if !$0 { pendingImpact = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingImpact = nil }
            Button("Delete Permanently", role: .destructive) {
                if let pendingImpact { onPermanentDelete?(pendingImpact) }
                pendingImpact = nil
            }
        } message: {
            if let impact = pendingImpact {
                Text("This cannot be undone. It affects \(impact.sessionCount) sessions, \(impact.proofCount) proofs, and \(impact.attachmentPaths.count) attachments.")
            }
        }
        .alert("Could not restore project", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var trashedProjects: [Project] {
        viewModel.projects.filter { $0.status == .trash }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func restore(_ project: Project) {
        do { try viewModel.restoreFromTrash(projectId: project.id) }
        catch { errorMessage = error.localizedDescription }
    }
}
