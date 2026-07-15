import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

struct AddProofView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: JournalViewModel
    var project: Project
    var session: LearningSession?

    @StateObject private var audioRecorder = AudioProofRecorder()
    @State private var type: ProofType = .image
    @State private var title = ""
    @State private var statement = ""
    @State private var linkText = ""
    @State private var artifactBody = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedAttachmentData: Data?
    @State private var selectedFileURL: URL?
    @State private var selectedFileName = ""
    @State private var selectedMimeType: String?
    @State private var isImportingFile = false
    @State private var isShowingCamera = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Proof") {
                    Picker("Type", selection: $type) {
                        ForEach(ProofType.allCases, id: \.self) { proofType in
                            Text(proofType.rawValue).tag(proofType)
                        }
                    }
                    TextField("Title", text: $title)
                    TextField("What does this prove?", text: $statement, axis: .vertical)
                }

                Section("Attach") {
                    #if os(iOS)
                    if CameraProofPicker.isAvailable {
                        Button {
                            isShowingCamera = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                    }
                    #endif

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Choose Photo", systemImage: "photo")
                    }

                    Button {
                        isImportingFile = true
                    } label: {
                        Label("Choose File", systemImage: "doc")
                    }

                    Button {
                        toggleRecording()
                    } label: {
                        Label(
                            audioRecorder.isRecording ? "Stop Recording" : "Record Audio",
                            systemImage: audioRecorder.isRecording ? "stop.circle" : "waveform.circle"
                        )
                    }

                    if !selectedFileName.isEmpty {
                        Label(selectedFileName, systemImage: iconName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if type == .link {
                    Section("Link") {
                        TextField("URL", text: $linkText)
                            .textContentType(.URL)
                    }
                }

                if type == .text {
                    Section("Artifact") {
                        TextEditor(text: $artifactBody)
                            .frame(minHeight: 180)
                        Text("Write or paste the inspectable result. This is separate from what you claim it proves.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Proof")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveProof()
                    }
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                loadPhoto(newItem)
            }
            .fileImporter(
                isPresented: $isImportingFile,
                allowedContentTypes: [.image, .audio, .pdf, .data, .item],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            #if os(iOS)
            .sheet(isPresented: $isShowingCamera) {
                CameraProofPicker { data in
                    applyAttachmentDraft(.capturedPhoto(data))
                }
            }
            #endif
            .alert("Could not add Proof", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var iconName: String {
        switch type {
        case .image: "photo"
        case .audio: "waveform"
        case .file: "doc"
        case .link: "link"
        case .text: "text.alignleft"
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                applyAttachmentDraft(
                    .selectedPhoto(data, contentType: item.supportedContentTypes.first)
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        do {
            guard let fileURL = try result.get().first else { return }
            applyAttachmentDraft(.importedFile(fileURL))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleRecording() {
        do {
            if audioRecorder.isRecording {
                guard let recordingURL = audioRecorder.stopRecording() else { return }
                applyAttachmentDraft(
                    ProofAttachmentDraft(
                        data: nil,
                        fileURL: recordingURL,
                        fileName: recordingURL.lastPathComponent,
                        mimeType: "audio/m4a",
                        proofType: .audio,
                        suggestedTitle: "Audio Proof"
                    )
                )
            } else {
                try audioRecorder.startRecording()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveProof() {
        do {
            try validateDraft()
            if type == .link {
                _ = try viewModel.addProof(
                    projectId: project.id,
                    sessionId: session?.id,
                    type: .link,
                    title: title,
                    statement: statement,
                    url: URL(string: linkText.trimmedForJournal)
                )
            } else if type == .text {
                _ = try viewModel.addProof(
                    projectId: project.id,
                    sessionId: session?.id,
                    type: .text,
                    title: title,
                    statement: statement,
                    artifactBody: artifactBody
                )
            } else if let data = selectedAttachmentData {
                _ = try viewModel.addProofFromAttachmentData(
                    data,
                    projectId: project.id,
                    sessionId: session?.id,
                    type: type,
                    title: title,
                    statement: statement,
                    originalFileName: selectedFileName.isEmpty ? "proof" : selectedFileName,
                    mimeType: selectedMimeType
                )
            } else if let fileURL = selectedFileURL {
                let didAccess = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }
                _ = try viewModel.addProofFromFile(
                    fileURL: fileURL,
                    projectId: project.id,
                    sessionId: session?.id,
                    type: type,
                    title: title,
                    statement: statement,
                    mimeType: selectedMimeType
                )
            } else {
                _ = try viewModel.addProof(
                    projectId: project.id,
                    sessionId: session?.id,
                    type: type,
                    title: title,
                    statement: statement
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func validateDraft() throws {
        guard !statement.trimmedForJournal.isEmpty else {
            throw JournalValidationError.emptyProofStatement
        }
        switch type {
        case .text:
            guard !artifactBody.trimmedForJournal.isEmpty else {
                throw JournalValidationError.missingProofArtifact
            }
        case .link:
            guard let url = URL(string: linkText.trimmedForJournal),
                  ProofArtifact.isValidWebURL(url) else {
                throw JournalValidationError.invalidProofURL
            }
        case .image, .audio, .file:
            let hasReadableData = selectedAttachmentData?.isEmpty == false
            let hasReadableFile = selectedFileURL.map {
                FileManager.default.isReadableFile(atPath: $0.path)
            } ?? false
            guard hasReadableData || hasReadableFile else {
                throw JournalValidationError.missingProofArtifact
            }
        }
    }

    private func applyAttachmentDraft(_ draft: ProofAttachmentDraft) {
        selectedAttachmentData = draft.data
        selectedFileURL = draft.fileURL
        selectedFileName = draft.fileName
        selectedMimeType = draft.mimeType
        type = draft.proofType
        if title.trimmedForJournal.isEmpty {
            title = draft.suggestedTitle
        }
    }
}

@MainActor
private final class AudioProofRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func startRecording() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proof-\(UUID().uuidString).m4a")

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
        #endif

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.record()
        self.recorder = recorder
        self.recordingURL = url
        isRecording = true
    }

    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        isRecording = false
        return recordingURL
    }
}

#if os(iOS)
private struct CameraProofPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onCapture: (Data) -> Void

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraProofPicker

        init(parent: CameraProofPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if
                let image = info[.originalImage] as? UIImage,
                let data = image.jpegData(compressionQuality: 0.9)
            {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
