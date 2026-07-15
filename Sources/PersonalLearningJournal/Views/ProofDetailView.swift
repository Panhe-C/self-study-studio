import AVFoundation
import SwiftUI

#if os(iOS)
import QuickLook
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ProofDetailView: View {
    @ObservedObject var viewModel: JournalViewModel
    let proof: Proof
    let projectName: String
    let sessionSummary: String

    @StateObject private var audioPlayer = ProofAudioPlayer()
    @State private var isShowingFilePreview = false
    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editStatement = ""
    @State private var editArtifactBody = ""
    @State private var errorMessage: String?

    private var currentProof: Proof {
        viewModel.proofs.first(where: { $0.id == proof.id }) ?? proof
    }

    private var preview: ProofPreviewDescriptor {
        ProofPreviewDescriptor(proof: currentProof)
    }

    var body: some View {
        List {
            Section("Proof") {
                Text(currentProof.title)
                    .font(.headline)
                Text(currentProof.statement)
                Label(projectName, systemImage: "folder")
                Label(sessionSummary, systemImage: "clock")
                Label(
                    currentProof.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )
            }

            Section("Attachment") {
                attachmentView
            }

            if !viewModel.proofRevisions(for: proof.id).isEmpty {
                Section("proof.revision_history") {
                    ForEach(viewModel.proofRevisions(for: proof.id)) { revision in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Revision \(revision.revision) · \(revision.title)")
                                .font(.subheadline.bold())
                            Text(revision.statement)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Proof")
        .toolbar {
            Button("Revise") {
                editTitle = currentProof.title
                editStatement = currentProof.statement
                editArtifactBody = currentProof.artifactBody ?? ""
                isEditing = true
            }
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                Form {
                    TextField("Title", text: $editTitle)
                    TextField("proof.statement", text: $editStatement, axis: .vertical)
                    if currentProof.type == .text {
                        TextEditor(text: $editArtifactBody)
                            .frame(minHeight: 180)
                    } else {
                        Text("The artifact remains unchanged; this revision updates its title and claim.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Revise Proof")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("action.cancel") { isEditing = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("action.save") { saveRevision() }
                    }
                }
            }
        }
        .alert("Could not revise Proof", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingFilePreview) {
            if case let .file(url) = preview.kind {
                QuickLookFilePreview(url: url)
            }
        }
        #endif
    }

    @ViewBuilder
    private var attachmentView: some View {
        switch preview.kind {
        case let .image(url):
            LocalProofImage(url: url)
        case let .audio(url):
            Button {
                audioPlayer.toggle(url: url)
            } label: {
                Label(
                    audioPlayer.isPlaying ? "Pause Recording" : "Play Recording",
                    systemImage: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                )
            }
        case let .file(url):
            #if os(iOS)
            Button {
                isShowingFilePreview = true
            } label: {
                Label("Open File", systemImage: "doc.richtext")
            }
            #else
            ShareLink(item: url) {
                Label("Share File", systemImage: "square.and.arrow.up")
            }
            #endif
        case let .link(url):
            Link(destination: url) {
                Label(url.absoluteString, systemImage: "link")
                    .lineLimit(2)
            }
        case let .text(markdown):
            ScrollView {
                Text(markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .unavailable:
            ContentUnavailableView(
                "Attachment Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The original file is not stored on this device.")
            )
        }
    }

    private func saveRevision() {
        do {
            _ = try viewModel.reviseProof(
                proofId: currentProof.id,
                title: editTitle,
                statement: editStatement,
                artifactBody: currentProof.type == .text ? editArtifactBody : nil
            )
            isEditing = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private final class ProofAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }

        do {
            if player?.url != url {
                player = try AVAudioPlayer(contentsOf: url)
                player?.delegate = self
            }
            player?.play()
            isPlaying = true
        } catch {
            isPlaying = false
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
        }
    }
}

private struct LocalProofImage: View {
    let url: URL

    var body: some View {
        #if os(iOS)
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            unavailableImage
        }
        #elseif os(macOS)
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            unavailableImage
        }
        #else
        unavailableImage
        #endif
    }

    private var unavailableImage: some View {
        ContentUnavailableView(
            "Image Unavailable",
            systemImage: "photo.badge.exclamationmark",
            description: Text("The original image could not be loaded.")
        )
    }
}

#if os(iOS)
private struct QuickLookFilePreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif
