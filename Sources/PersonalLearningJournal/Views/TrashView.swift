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
            if !viewModel.pendingAttachmentCleanupPaths.isEmpty {
                Section("Pending attachment cleanup") {
                    Text("Some attachment files still need cleanup. This local retry queue survives leaving and reopening Trash.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry attachment cleanup") {
                        do {
                            try viewModel.retryPendingAttachmentCleanup()
                            errorMessage = nil
                        } catch {
                            errorMessage = error.localizedDescription
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
                    Text("\(impact.sessionCount) sessions · \(impact.proofCount) proofs · \(impact.revisionCount) revisions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(impact.routineCount) routines · \(impact.practiceSessionCount) practice sessions · \(impact.attachmentPaths.count) attachments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(impact.reviewCount) reviews · \(impact.trailCount) trail events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("trash.restore") { restore(project) }
                        Spacer()
                        Button("Export Before Delete") { export(project) }
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
                Text("This cannot be undone. It affects \(impact.planCount) plans, \(impact.sessionCount) sessions, \(impact.proofCount) proofs, \(impact.routineCount) routines, \(impact.practiceSessionCount) practice sessions, \(impact.reviewCount) reviews, \(impact.trailCount) trail events, and \(impact.attachmentPaths.count) attachments.")
            }
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

    private func export(_ project: Project) {
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
                to: exportDirectory
            )
            if let onExport {
                onExport(project, try Data(contentsOf: document.url))
            }
            exportDocument = document
            noticeMessage = "Export prepared with \(document.attachmentCount) attachments before deleting \(project.name)."
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
