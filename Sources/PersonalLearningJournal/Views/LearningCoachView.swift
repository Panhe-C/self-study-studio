import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

public struct LearningCoachMessage: Equatable, Identifiable, Sendable {
    public enum Role: Equatable, Sendable { case learner, coach }

    public let id: UUID
    public let role: Role
    public let content: String
    public let attachments: [LearningCoachAttachment]

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        attachments: [LearningCoachAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
    }
}

public struct LearningCoachView: View {
    @ObservedObject private var viewModel: JournalViewModel
    private let provider: any LearningCoachProviding
    @State private var selectedProjectID: UUID?
    @State private var messages: [LearningCoachMessage] = []
    @State private var draft = ""
    @State private var attachments: [LearningCoachAttachment] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showingAISettings = false

    public init(
        viewModel: JournalViewModel,
        provider: any LearningCoachProviding = AdaptiveLearningCoachProvider()
    ) {
        self.viewModel = viewModel
        self.provider = provider
    }

    private var projects: [Project] {
        viewModel.snapshot.projects
            .filter { !$0.isTrashed && $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID } ?? projects.first
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let project = selectedProject {
                projectPicker(project)
                conversation(project)
                composer
            } else {
                ContentUnavailableView(
                    String(localized: "coach.empty.title"),
                    systemImage: "sparkles",
                    description: Text("coach.empty.detail")
                )
            }
        }
        .background(StudioTheme.pageBackground.ignoresSafeArea())
        .navigationTitle(Text("coach.title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAISettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel(Text("root.menu.ai_settings"))
            }
        }
        .sheet(isPresented: $showingAISettings) { AIReviewSettingsView() }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.pdf, .plainText, .sourceCode, .json],
            allowsMultipleSelection: true
        ) { result in
            importFiles(result)
        }
        .alert(String(localized: "coach.error.title"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { selectFirstProjectIfNeeded() }
        .onChange(of: projects.map(\.id)) { _, _ in selectFirstProjectIfNeeded() }
        .onChange(of: selectedProjectID) { _, _ in
            messages = []
            attachments = []
        }
        .onChange(of: selectedPhotoItem) { _, item in loadPhoto(item) }
    }

    private func projectPicker(_ project: Project) -> some View {
        Menu {
            ForEach(projects) { item in
                Button {
                    selectedProjectID = item.id
                } label: {
                    if item.id == project.id {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(StudioTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("coach.context").font(.caption).foregroundStyle(.secondary)
                    Text(project.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, StudioTheme.pageInset)
            .padding(.vertical, 12)
            .background(.background)
        }
        .buttonStyle(.plain)
    }

    private func conversation(_ project: Project) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if messages.isEmpty {
                        welcome(project)
                    }
                    ForEach(messages) { message in
                        bubble(message).id(message.id)
                    }
                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("coach.thinking").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, StudioTheme.pageInset)
                    }
                }
                .padding(.vertical, 16)
            }
            .onChange(of: messages.count) { _, _ in
                if let id = messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func welcome(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(StudioTheme.accent)
            Text(String(format: String(localized: "coach.welcome"), project.name))
                .font(.title3.weight(.bold))
            Text("coach.welcome.detail")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                suggestion("coach.prompt.next_step")
                suggestion("coach.prompt.review")
                suggestion("coach.prompt.stuck")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, StudioTheme.pageInset)
    }

    private func suggestion(_ key: String) -> some View {
        Button {
            draft = String(localized: String.LocalizationValue(key))
        } label: {
            HStack {
                Text(LocalizedStringKey(key)).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .font(.subheadline.weight(.medium))
            .padding(12)
            .background(StudioTheme.mutedSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func bubble(_ message: LearningCoachMessage) -> some View {
        HStack {
            if message.role == .learner { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 9) {
                if !message.attachments.isEmpty {
                    attachmentSummary(message.attachments, removable: false)
                }
                richText(message.content)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .foregroundStyle(message.role == .learner ? Color.white : Color.primary)
            .tint(message.role == .learner ? Color.white : StudioTheme.accent)
            .background(
                message.role == .learner ? StudioTheme.accent : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            if message.role == .coach { Spacer(minLength: 44) }
        }
        .padding(.horizontal, StudioTheme.pageInset)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                attachmentSummary(attachments, removable: true)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("coach.attachment.photo", systemImage: "photo")
                    }
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("coach.attachment.file", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.semibold))
                        .frame(width: 42, height: 42)
                        .background(StudioTheme.mutedSurface.opacity(0.8), in: Circle())
                }
                .disabled(isSending || attachments.count >= LearningCoachAttachment.maximumAttachmentCount)

                TextField("coach.placeholder", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(StudioTheme.mutedSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
                    .submitLabel(.send)
                    .onSubmit { send() }
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(StudioTheme.accent, in: Circle())
                }
                .disabled(isSending || !canSend)
                .opacity(isSending || !canSend ? 0.45 : 1)
            }
        }
        .padding(.horizontal, StudioTheme.pageInset)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func send() {
        let typedQuestion = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = typedQuestion.isEmpty
            ? String(localized: "coach.attachment.default_question")
            : typedQuestion
        guard canSend, !isSending, let project = selectedProject,
              let context = LearningCoachContextProjector.project(
                snapshot: viewModel.snapshot,
                projectID: project.id
              ) else { return }
        let history = messages.map {
            LearningCoachTurn(
                role: $0.role == .learner ? "learner" : "coach",
                content: $0.content
            )
        }
        let sentAttachments = attachments
        messages.append(LearningCoachMessage(
            role: .learner,
            content: question,
            attachments: sentAttachments
        ))
        draft = ""
        attachments = []
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let reply = try await provider.reply(
                    context: context,
                    conversation: history,
                    question: question,
                    attachments: sentAttachments
                )
                messages.append(LearningCoachMessage(role: .coach, content: reply))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func richText(_ content: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .full)
        ) {
            return Text(attributed)
        }
        return Text(content)
    }

    private func attachmentSummary(
        _ items: [LearningCoachAttachment],
        removable: Bool
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.kind == .image ? "photo.fill" : "doc.fill")
                        Text(item.fileName)
                            .lineLimit(1)
                            .frame(maxWidth: 150)
                        if removable {
                            Button {
                                attachments.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("coach.attachment.remove"))
                        }
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { selectedPhotoItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw LearningCoachAttachmentError.unsupportedFile
                }
                let type = item.supportedContentTypes.first ?? .jpeg
                try addAttachments([
                    LearningCoachAttachment.image(
                        data: data,
                        fileName: "photo.\(type.preferredFilenameExtension ?? "jpg")",
                        mimeType: type.preferredMIMEType ?? "image/jpeg"
                    )
                ])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            let imported = try result.get().map(LearningCoachAttachment.file(url:))
            try addAttachments(imported)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addAttachments(_ newItems: [LearningCoachAttachment]) throws {
        guard attachments.count + newItems.count <= LearningCoachAttachment.maximumAttachmentCount else {
            throw LearningCoachAttachmentError.tooManyAttachments
        }
        attachments.append(contentsOf: newItems)
    }

    private func selectFirstProjectIfNeeded() {
        if !projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = projects.first?.id
        }
    }
}
