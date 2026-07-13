import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct LibraryView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @State private var grouping: LibraryGrouping = .time
    @State private var isChoosingProjectForProof = false
    @State private var projectForProof: Project?
    @State private var notice: LibraryNotice?
    @State private var selectedFilter: StudioLibraryFilter = .evidence
    @State private var searchText = ""

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Library mode", selection: $selectedFilter) {
                ForEach(StudioLibraryFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, StudioTheme.pageInset)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let review = viewModel.reviews.last {
                        NavigationLink {
                            ReviewView(viewModel: viewModel, review: review)
                        } label: {
                            reviewBanner(review)
                        }
                        .buttonStyle(.plain)
                    }

                    switch selectedFilter {
                    case .evidence:
                        evidenceGrid
                    case .reviews:
                        reviewsList
                    case .exports:
                        exportPanel
                    }
                }
                .padding(.horizontal, StudioTheme.pageInset)
                .padding(.bottom, 24)
            }
        }
        .background(StudioTheme.pageBackground.ignoresSafeArea())
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search your library")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Group evidence", selection: $grouping) {
                        ForEach(LibraryGrouping.allCases) { grouping in
                            Text(grouping.rawValue).tag(grouping)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Group evidence")

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

    private var filteredProofs: [Proof] {
        viewModel.proofs
            .filter { StudioPresentation.proofMatches(query: searchText, proof: $0, projectName: projectName(for: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var evidenceGrid: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(filteredSections) { section in
                StudioSectionHeader(title: section.title)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 16) {
                    ForEach(section.proofs) { proof in
                        NavigationLink {
                            ProofDetailView(proof: proof, projectName: projectName(for: proof), sessionSummary: sessionSummary(for: proof))
                        } label: {
                            evidenceCard(proof)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var filteredSections: [ProofSection] {
        let allowed = Set(filteredProofs.map(\.id))
        return sectionedProofs.compactMap { section in
            let proofs = section.proofs.filter { allowed.contains($0.id) }
            return proofs.isEmpty ? nil : ProofSection(title: section.title, proofs: proofs)
        }
    }

    private var reviewsList: some View {
        VStack(spacing: 12) {
            ForEach(viewModel.reviews.sorted { $0.periodEnd > $1.periodEnd }) { review in
                NavigationLink {
                    ReviewView(viewModel: viewModel, review: review)
                } label: {
                    reviewBanner(review)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "square.and.arrow.up")
                .font(.largeTitle)
                .foregroundStyle(StudioTheme.accent)
            Text("Export your learning archive")
                .font(.title3.bold())
            Text("Creates a portable journal file and copies all available attachments.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Create Export", action: exportJournal)
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func evidenceCard(_ proof: Proof) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            proofPreview(proof)
            Text(proof.title).font(.subheadline.bold()).lineLimit(2)
            Text(projectName(for: proof)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(proof.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func proofPreview(_ proof: Proof) -> some View {
        let descriptor = ProofPreviewDescriptor(proof: proof)
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(StudioTheme.mutedSurface)
            if case let .image(url) = descriptor.kind {
                #if canImport(UIKit)
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    previewIcon(for: proof.type)
                }
                #else
                previewIcon(for: proof.type)
                #endif
            } else {
                previewIcon(for: proof.type)
            }
        }
        .aspectRatio(1.15, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func previewIcon(for type: ProofType) -> some View {
        Image(systemName: proofIcon(for: type))
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(type == .audio ? StudioTheme.completed : StudioTheme.accent)
    }

    private func reviewBanner(_ review: Review) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "pin.fill")
                .foregroundStyle(StudioTheme.completed)
            VStack(alignment: .leading, spacing: 3) {
                Text("Weekly Review · \(review.periodEnd.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline.bold())
                Text(review.decisions.first ?? "Review your learning evidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func proofIcon(for type: ProofType) -> String {
        switch type {
        case .image: "photo.fill"
        case .audio: "waveform"
        case .file: "doc.text.fill"
        case .link: "link"
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
