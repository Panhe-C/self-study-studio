import SwiftUI

public struct LibraryView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @State private var grouping: LibraryGrouping = .time
    @State private var isChoosingProjectForProof = false
    @State private var projectForProof: Project?
    @State private var notice: LibraryNotice?

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            Section {
                Picker("View", selection: $grouping) {
                    ForEach(LibraryGrouping.allCases) { grouping in
                        Text(grouping.rawValue).tag(grouping)
                    }
                }
                .pickerStyle(.segmented)
            }

            ForEach(sectionedProofs) { section in
                Section(section.title) {
                    ForEach(section.proofs) { proof in
                        NavigationLink {
                            ProofDetailView(
                                proof: proof,
                                projectName: projectName(for: proof),
                                sessionSummary: sessionSummary(for: proof)
                            )
                        } label: {
                            ProofRow(
                                proof: proof,
                                projectName: projectName(for: proof),
                                sessionSummary: sessionSummary(for: proof)
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isChoosingProjectForProof = true
                } label: {
                    Label("Add Proof", systemImage: "paperclip.badge.plus")
                }
                .disabled(viewModel.projects.isEmpty)

                Button {
                    exportJournal()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $isChoosingProjectForProof) {
            LibraryProjectPickerView(projects: viewModel.projects) { project in
                projectForProof = project
                isChoosingProjectForProof = false
            }
        }
        .sheet(item: $projectForProof) { project in
            AddProofView(viewModel: viewModel, project: project, session: nil)
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var sectionedProofs: [ProofSection] {
        switch grouping {
        case .time:
            return timeSections
        case .project:
            return groupedSections { projectName(for: $0) }
        case .type:
            return groupedSections { $0.type.rawValue.capitalized }
        }
    }

    private var timeSections: [ProofSection] {
        let grouped = Dictionary(grouping: viewModel.proofs) { proof in
            Calendar.current.startOfDay(for: proof.createdAt)
        }

        return grouped.keys
            .sorted(by: >)
            .map { day in
                ProofSection(
                    title: day.formatted(date: .abbreviated, time: .omitted),
                    proofs: grouped[day, default: []].sorted { $0.createdAt > $1.createdAt }
                )
            }
    }

    private func groupedSections(
        by title: (Proof) -> String
    ) -> [ProofSection] {
        let grouped = Dictionary(grouping: viewModel.proofs, by: title)

        return grouped.keys
            .sorted()
            .map { key in
                ProofSection(
                    title: key,
                    proofs: grouped[key, default: []].sorted { $0.createdAt > $1.createdAt }
                )
            }
    }

    private func projectName(for proof: Proof) -> String {
        viewModel.projects.first { $0.id == proof.projectId }?.name ?? "Unknown Project"
    }

    private func sessionSummary(for proof: Proof) -> String {
        guard let sessionId = proof.sessionId else {
            return "Project-level Proof"
        }
        guard let session = viewModel.sessions.first(where: { $0.id == sessionId }) else {
            return "Session unavailable"
        }
        return "\(session.durationMinutes) min · \(session.actionType.rawValue) · \(session.note)"
    }

    private func exportJournal() {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let stamp = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let exportDirectory = documents
                .appendingPathComponent("LearningJournal", isDirectory: true)
                .appendingPathComponent("Exports", isDirectory: true)
                .appendingPathComponent("export-\(stamp)", isDirectory: true)
            let bundle = try viewModel.exportBundle(to: exportDirectory)
            notice = LibraryNotice(
                title: "Export Ready",
                message: "Saved journal.json and \(bundle.attachmentURLs.count) attachments to \(exportDirectory.path)."
            )
        } catch {
            notice = LibraryNotice(
                title: "Export Failed",
                message: error.localizedDescription
            )
        }
    }
}

private enum LibraryGrouping: String, CaseIterable, Identifiable {
    case time = "Time"
    case project = "Project"
    case type = "Type"

    var id: Self { self }
}

private struct ProofSection: Identifiable {
    var title: String
    var proofs: [Proof]

    var id: String { title }
}

private struct LibraryNotice: Identifiable {
    var id = UUID()
    var title: String
    var message: String
}

private struct LibraryProjectPickerView: View {
    @Environment(\.dismiss) private var dismiss
    var projects: [Project]
    var onSelect: (Project) -> Void

    var body: some View {
        NavigationStack {
            List(projects) { project in
                Button {
                    onSelect(project)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .font(.headline)
                        Text(project.currentNextStep.isEmpty ? "No Next Step" : project.currentNextStep)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Choose Project")
        }
    }
}

private struct ProofRow: View {
    var proof: Proof
    var projectName: String
    var sessionSummary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(proof.title, systemImage: iconName(for: proof.type))
                    .font(.headline)
                Spacer()
                Text(proof.type.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(proof.statement)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 4) {
                Label(projectName, systemImage: "folder")
                Label(sessionSummary, systemImage: "clock")
                    .lineLimit(2)
                Label(
                    proof.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )
                if let attachmentLabel {
                    Label(attachmentLabel, systemImage: iconName(for: proof.type))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var attachmentLabel: String? {
        if let url = proof.url {
            return url.absoluteString
        }

        guard let localPath = proof.localPath else {
            return nil
        }

        return URL(fileURLWithPath: localPath).lastPathComponent
    }

    private func iconName(for type: ProofType) -> String {
        switch type {
        case .image: "photo"
        case .audio: "waveform"
        case .file: "doc"
        case .link: "link"
        }
    }
}
