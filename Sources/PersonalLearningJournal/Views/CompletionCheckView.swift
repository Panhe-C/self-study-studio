import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The completion check (spec 9.2): progress (required), completed items,
/// understanding (optional), blocker (optional), attachments (always
/// optional). Uses only standard Pickers/Toggles/TextFields — the AI draft
/// supplies wording, never UI, and answers never come preselected.
public struct CompletionCheckView: View {
    @ObservedObject var controller: StudyFlowController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var progress: CompletionProgress?
    @State private var completedCriterionIDs: Set<String> = []
    @State private var understanding: UnderstandingLevel?
    @State private var blocker = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var isSubmitting = false
    @State private var attachmentError: String?

    public init(controller: StudyFlowController) {
        self.controller = controller
    }

    private var draft: CompletionCheckDraft? {
        controller.currentCapture?.checkDraft
    }

    private var stagedAttachments: [PendingAttachmentReference] {
        controller.currentCapture?.stagedAttachments ?? []
    }

    private var prefersVerticalLayout: Bool {
        StudyFlowViewState.prefersVerticalLayout(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    public var body: some View {
        Form {
            if let draft {
                Section {
                    Text(draft.activityTitle)
                        .font(.headline)
                    Text(StudyFlowCopy.draftSourceTitle(draft.source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker(selection: $progress) {
                        Text("study_flow.check.progress.placeholder")
                            .tag(CompletionProgress?.none)
                        ForEach(draft.progressOptions, id: \.self) { option in
                            Text(StudyFlowCopy.progressTitle(option))
                                .tag(CompletionProgress?.some(option))
                        }
                    } label: {
                        Text("study_flow.check.progress")
                    }
                    .accessibilityLabel(Text("study_flow.check.progress"))
                } header: {
                    Text("study_flow.check.progress")
                } footer: {
                    Text("study_flow.check.progress.required")
                }

                if !draft.criteria.isEmpty {
                    Section("study_flow.check.criteria") {
                        ForEach(draft.criteria) { criterion in
                            Toggle(
                                criterion.text,
                                isOn: criterionBinding(criterion.id)
                            )
                        }
                    }
                }

                if draft.asksUnderstanding {
                    Section("study_flow.check.understanding") {
                        Picker(selection: $understanding) {
                            Text("study_flow.check.understanding.placeholder")
                                .tag(UnderstandingLevel?.none)
                            ForEach(UnderstandingLevel.allCases, id: \.self) { level in
                                Text(StudyFlowCopy.understandingTitle(level))
                                    .tag(UnderstandingLevel?.some(level))
                            }
                        } label: {
                            Text("study_flow.check.understanding")
                        }
                        .accessibilityLabel(Text("study_flow.check.understanding"))
                    }
                }

                if draft.asksBlocker {
                    Section("study_flow.check.blocker") {
                        TextField(
                            "study_flow.check.blocker.placeholder",
                            text: $blocker,
                            axis: .vertical
                        )
                    }
                }

                Section("study_flow.check.attachments") {
                    ForEach(stagedAttachments) { attachment in
                        Label(attachment.displayName, systemImage: "paperclip")
                            .font(.subheadline)
                    }
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("study_flow.check.add_photo", systemImage: "photo")
                    }
                    Button {
                        isImportingFile = true
                    } label: {
                        Label("study_flow.check.add_file", systemImage: "doc")
                    }
                }

                Section {
                    if prefersVerticalLayout {
                        VStack(spacing: 10) {
                            continueButton
                            laterButton
                        }
                    } else {
                        continueButton
                        laterButton
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text("study_flow.check.title"))
        .onAppear(perform: prefillAnswers)
        .onChange(of: selectedPhotoItem) { _, item in
            stagePhoto(item)
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.image, .pdf, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            stageImportedFile(result)
        }
        .alert(
            "study_flow.error.title",
            isPresented: .constant(attachmentError != nil)
        ) {
            Button("OK") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
    }

    private var continueButton: some View {
        Button {
            guard !isSubmitting else { return }
            isSubmitting = true
            Task {
                await controller.submitAnswers(currentAnswers())
                isSubmitting = false
            }
        } label: {
            Text("study_flow.check.continue")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(StudioTheme.accent)
        .disabled(progress == nil || isSubmitting)
        .accessibilityLabel(Text("study_flow.check.continue"))
    }

    private var laterButton: some View {
        Button {
            controller.saveForLater()
        } label: {
            Text("study_flow.check.later")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("study_flow.check.later"))
    }

    private func criterionBinding(_ id: String) -> Binding<Bool> {
        Binding {
            completedCriterionIDs.contains(id)
        } set: { isOn in
            if isOn {
                completedCriterionIDs.insert(id)
            } else {
                completedCriterionIDs.remove(id)
            }
        }
    }

    private func currentAnswers() -> CompletionCheckAnswers {
        CompletionCheckAnswers(
            progress: progress,
            completedCriterionIDs: completedCriterionIDs.sorted(),
            understanding: understanding,
            blocker: blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : blocker.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Prefills the user's OWN previous answers when returning from the
    /// record draft or reopening a saved check. Drafts never preselect.
    private func prefillAnswers() {
        guard let answers = controller.currentCapture?.answers else { return }
        progress = answers.progress
        completedCriterionIDs = Set(answers.completedCriterionIDs)
        understanding = answers.understanding
        blocker = answers.blocker ?? ""
    }

    private func stagePhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("study-attachment-\(UUID().uuidString).jpg")
                try data.write(to: url, options: [.atomic])
                controller.stageAttachment(
                    PendingAttachmentReference(
                        id: UUID(),
                        kind: .image,
                        localPath: url.path,
                        displayName: "photo.jpg",
                        fileSize: Int64(data.count)
                    )
                )
            } catch {
                attachmentError = error.localizedDescription
            }
            selectedPhotoItem = nil
        }
    }

    private func stageImportedFile(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            let stagingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("study-attachment-\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
            let isImage = (try? sourceURL.resourceValues(forKeys: [.contentTypeKey]))?
                .contentType?.conforms(to: .image) == true
            let size = (try? FileManager.default.attributesOfItem(atPath: stagingURL.path)[.size])
                as? Int64
            controller.stageAttachment(
                PendingAttachmentReference(
                    id: UUID(),
                    kind: isImage ? .image : .file,
                    localPath: stagingURL.path,
                    displayName: sourceURL.lastPathComponent,
                    fileSize: size
                )
            )
        } catch {
            attachmentError = error.localizedDescription
        }
    }
}
