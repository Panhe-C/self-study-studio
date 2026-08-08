import SwiftUI

public struct TrashView: View {
    @ObservedObject private var viewModel: JournalViewModel
    private let archiveService: JournalArchiveService
    private let trashExportService: TrashExportService
    private let onPermanentDelete: ((TrashPurgeImpact) -> Void)?
    private let onExport: ((Project, Data) -> Void)?
    @State private var pendingImpact: TrashPurgeImpact?
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var exportDocument: TrashExportDocument?
    @State private var pendingUnencryptedExportProject: Project?
    @State private var pendingOrphanCleanupPaths: [String] = []
    @State private var pendingCorruptQueueQuarantineConfirmation = false

    public init(
        viewModel: JournalViewModel,
        archiveService: JournalArchiveService = JournalArchiveService(),
        trashExportService: TrashExportService = TrashExportService(),
        onPermanentDelete: ((TrashPurgeImpact) -> Void)? = nil,
        onExport: ((Project, Data) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.archiveService = archiveService
        self.trashExportService = trashExportService
        self.onPermanentDelete = onPermanentDelete
        self.onExport = onExport
    }

    public var body: some View {
        List {
            Section {
                Text("trash.retention_notice")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !viewModel.pendingAttachmentCleanupPaths.isEmpty
                || !viewModel.pendingAttachmentCleanupOrphanPaths.isEmpty
                || viewModel.attachmentCleanupQueueError != nil
                || viewModel.attachmentCleanupQueueQuarantineURL != nil {
                Section("Pending attachment cleanup") {
                    if let queueError = viewModel.attachmentCleanupQueueError {
                        Text(queueError.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Text("Some attachment files still need cleanup. This local retry queue survives leaving and reopening Trash.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if viewModel.attachmentCleanupQueueError == .invalidQueue
                        || viewModel.attachmentCleanupQueueError == .quarantineFailed {
                        Button("Quarantine corrupt queue") {
                            pendingCorruptQueueQuarantineConfirmation = true
                        }
                    } else if viewModel.attachmentCleanupQueueError != nil {
                        Button("Recover attachment cleanup queue") {
                            do {
                                try viewModel.recoverAttachmentCleanupQueue()
                                errorMessage = nil
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    if !viewModel.pendingAttachmentCleanupOrphanPaths.isEmpty {
                        Text("Orphan paths awaiting confirmation: \(viewModel.pendingAttachmentCleanupOrphanPaths.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Button("Review orphan cleanup") {
                            pendingOrphanCleanupPaths = viewModel.pendingAttachmentCleanupOrphanPaths
                        }
                    }
                    if !viewModel.pendingAttachmentCleanupPaths.isEmpty {
                        Button("Retry attachment cleanup") {
                            do {
                                try viewModel.retryPendingAttachmentCleanup()
                                errorMessage = nil
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    if let quarantineURL = viewModel.attachmentCleanupQueueQuarantineURL {
                        Text("Quarantined queue: \(quarantineURL.lastPathComponent)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ShareLink(item: quarantineURL) {
                            Label("Share quarantined queue", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            ForEach(trashedProjects) { project in
                let impact = archiveService.purgeImpact(projectID: project.id, snapshot: viewModel.snapshot)
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.name).font(.headline)
                    Text("\(impact.planCount) plans · \(impact.phaseCount) phases · \(impact.plannedSessionCount) planned sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(impact.contractCount) contracts · \(impact.acceptanceCount) acceptances · \(impact.decisionCount) decisions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(impact.sessionCount) sessions · \(impact.proofCount) proofs · \(impact.revisionCount) revisions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(impact.routineCount) routines · \(impact.practiceSessionCount) practice sessions · \(impact.attachmentPaths.count) attachments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(impact.reviewCount) reviews deleted · \(impact.reviewUpdateCount) shared reviews updated · \(impact.trailCount) trail events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("trash.restore") { restore(project) }
                        Spacer()
                        Button("Export Before Delete") { pendingUnencryptedExportProject = project }
                        Button("trash.delete_permanently", role: .destructive) { pendingImpact = impact }
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
                if let pendingImpact {
                    if let onPermanentDelete {
                        onPermanentDelete(pendingImpact)
                    } else {
                        do {
                            _ = try viewModel.permanentlyDelete(projectId: pendingImpact.projectID)
                        } catch let error as JournalArchiveError {
                            errorMessage = error.localizedDescription
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                pendingImpact = nil
            }
        } message: {
            if let impact = pendingImpact {
                Text("This cannot be undone. It affects \(impact.planCount) plans, \(impact.phaseCount) phases, \(impact.plannedSessionCount) planned sessions, \(impact.contractCount) contracts, \(impact.acceptanceCount) acceptances, \(impact.sessionCount) sessions, \(impact.proofCount) proofs, \(impact.revisionCount) revisions, \(impact.decisionCount) decisions, \(impact.routineCount) routines, \(impact.practiceSessionCount) practice sessions, \(impact.reviewCount) reviews deleted, \(impact.reviewUpdateCount) shared reviews updated, \(impact.trailCount) trail events, and \(impact.attachmentPaths.count) attachments.")
            }
        }
        .alert("Unencrypted export", isPresented: Binding(
            get: { pendingUnencryptedExportProject != nil },
            set: { if !$0 { pendingUnencryptedExportProject = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingUnencryptedExportProject = nil }
            Button("Continue", role: .destructive) {
                if let project = pendingUnencryptedExportProject {
                    export(project, confirmedUnencrypted: true)
                }
                pendingUnencryptedExportProject = nil
            }
        } message: {
            Text("This archive is unencrypted and may contain private learning history and attachments. Continue only if you will save or share it in a trusted location.")
        }
        .alert("Confirm orphan cleanup", isPresented: Binding(
            get: { !pendingOrphanCleanupPaths.isEmpty },
            set: { if !$0 { pendingOrphanCleanupPaths = [] } }
        )) {
            Button("Cancel", role: .cancel) { pendingOrphanCleanupPaths = [] }
            Button("Delete confirmed paths", role: .destructive) {
                let paths = pendingOrphanCleanupPaths
                do {
                    try viewModel.recoverLegacyOrphan(paths: paths, confirmed: true)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
                pendingOrphanCleanupPaths = []
            }
        } message: {
            Text("Only these paths under trusted attachment roots will be deleted:\n\(pendingOrphanCleanupPaths.joined(separator: "\n"))")
        }
        .alert("Quarantine corrupt queue?", isPresented: $pendingCorruptQueueQuarantineConfirmation) {
            Button("Cancel", role: .cancel) { pendingCorruptQueueQuarantineConfirmation = false }
            Button("Quarantine", role: .destructive) {
                do {
                    _ = try viewModel.quarantineCorruptQueue()
                    noticeMessage = "The corrupt queue was preserved in quarantine. Use Share quarantined queue to export it."
                } catch {
                    errorMessage = error.localizedDescription
                }
                pendingCorruptQueueQuarantineConfirmation = false
            }
        } message: {
            Text("The original corrupt queue will be moved to a timestamped quarantine file and kept for sharing. New cleanup work can continue only after this operation succeeds.")
        }
        .alert("Could not complete action", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            if !viewModel.pendingAttachmentCleanupPaths.isEmpty {
                Button("Retry attachment cleanup") {
                    do {
                        try viewModel.retryPendingAttachmentCleanup()
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("OK") {
                errorMessage = nil
            }
        } message: { Text(errorMessage ?? "") }
        .alert("Export ready", isPresented: Binding(
            get: { noticeMessage != nil },
            set: { if !$0 { noticeMessage = nil } }
        )) { Button("OK") { noticeMessage = nil } } message: { Text(noticeMessage ?? "") }
        .sheet(item: $exportDocument) { document in
            NavigationStack {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("Export is ready to save or share.")
                        .multilineTextAlignment(.center)
                    Label(
                        "This archive is unencrypted. Save or share it only in a trusted location.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    ShareLink(item: document.url) {
                        Label("Save or Share Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .navigationTitle("Export Ready")
            }
        }
    }

    private var trashedProjects: [Project] {
        viewModel.projects.filter(\.isTrashed).sorted { $0.updatedAt > $1.updatedAt }
    }

    private func restore(_ project: Project) {
        do { try viewModel.restoreFromTrash(projectId: project.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func export(_ project: Project, confirmedUnencrypted: Bool) {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let exportDirectory = documents
                .appendingPathComponent("LearningJournal", isDirectory: true)
                .appendingPathComponent("TrashExports", isDirectory: true)
            let document = try trashExportService.prepare(
                snapshot: viewModel.snapshot,
                project: project,
                to: exportDirectory,
                confirmedUnencrypted: confirmedUnencrypted
            )
            if let onExport {
                onExport(project, try Data(contentsOf: document.url))
            }
            exportDocument = document
            noticeMessage = "Unencrypted export prepared with \(document.attachmentCount) attachments before deleting \(project.name). Save it only in a trusted location."
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
