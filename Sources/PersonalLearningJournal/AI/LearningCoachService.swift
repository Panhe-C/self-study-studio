import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
import UniformTypeIdentifiers

public struct LearningCoachAttachment: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case image, document }

    public static let maximumAttachmentCount = 4
    public static let maximumImageBytes = 10 * 1_024 * 1_024
    public static let maximumDocumentBytes = 20 * 1_024 * 1_024

    public let id: UUID
    public let kind: Kind
    public let fileName: String
    public let mimeType: String
    public let data: Data
    public let extractedText: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        fileName: String,
        mimeType: String,
        data: Data,
        extractedText: String? = nil
    ) throws {
        guard data.count <= (kind == .image ? Self.maximumImageBytes : Self.maximumDocumentBytes) else {
            throw LearningCoachAttachmentError.fileTooLarge
        }
        if kind == .document {
            guard let extractedText, !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LearningCoachAttachmentError.unsupportedFile
            }
        }
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
        self.extractedText = extractedText
    }

    public static func image(data: Data, fileName: String, mimeType: String) throws -> Self {
        try Self(kind: .image, fileName: fileName, mimeType: mimeType, data: data)
    }

    public static func file(url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let text: String?
        if type.conforms(to: .pdf) {
            #if canImport(PDFKit)
            text = PDFDocument(data: data)?.string
            #else
            text = nil
            #endif
        } else if type.conforms(to: .text)
                    || type.conforms(to: .json)
                    || type.conforms(to: .sourceCode) {
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
        } else {
            text = nil
        }
        return try Self(
            kind: .document,
            fileName: url.lastPathComponent,
            mimeType: type.preferredMIMEType ?? "application/octet-stream",
            data: data,
            extractedText: text
        )
    }

    var aiInput: AIInputAttachment {
        AIInputAttachment(
            kind: kind == .image ? .image : .document,
            fileName: fileName,
            mimeType: mimeType,
            data: data,
            extractedText: extractedText
        )
    }
}

public enum LearningCoachAttachmentError: Error, Equatable, Sendable {
    case fileTooLarge
    case unsupportedFile
    case tooManyAttachments
}

extension LearningCoachAttachmentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileTooLarge: String(localized: "coach.attachment.too_large")
        case .unsupportedFile: String(localized: "coach.attachment.unsupported")
        case .tooManyAttachments: String(localized: "coach.attachment.too_many")
        }
    }
}

public struct LearningCoachContext: Codable, Equatable, Sendable {
    public struct Phase: Codable, Equatable, Sendable {
        public let title: String
        public let objective: String
        public let progress: String
    }

    public struct Record: Codable, Equatable, Sendable {
        public let date: Date
        public let kind: String
        public let minutes: Int
        public let note: String
    }

    public let projectName: String
    public let goal: String
    public let currentNextStep: String
    public let phases: [Phase]
    public let recentRecords: [Record]
}

public struct LearningCoachTurn: Codable, Equatable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum LearningCoachContextProjector {
    public static func project(snapshot: JournalSnapshot, projectID: UUID) -> LearningCoachContext? {
        guard let project = snapshot.projects.first(where: {
            $0.id == projectID && !$0.isTrashed && $0.deletedAt == nil
        }) else { return nil }
        let plan = snapshot.learningPlanAggregates(for: projectID)
            .compactMap(\.activeRevision)
            .first?.plan
            ?? project.activeCoursePlanId.flatMap { id in snapshot.coursePlans.first { $0.id == id } }
        let phases = plan.map { activePlan in
            snapshot.planPhases
                .filter { $0.planId == activePlan.id && $0.deletedAt == nil }
                .sorted { $0.ordinal < $1.ordinal }
                .map { phase in
                    LearningCoachContext.Phase(
                        title: phase.title,
                        objective: phase.objective,
                        progress: phase.progress.rawValue
                    )
                }
        } ?? []
        let records = snapshot.sessions
            .filter { $0.projectId == projectID && $0.deletedAt == nil }
            .sorted { $0.endedAt > $1.endedAt }
            .prefix(10)
            .map {
                LearningCoachContext.Record(
                    date: $0.endedAt,
                    kind: $0.actionType.rawValue,
                    minutes: $0.durationMinutes,
                    note: $0.note
                )
            }
        return LearningCoachContext(
            projectName: project.name,
            goal: project.goal,
            currentNextStep: project.currentNextStep,
            phases: phases,
            recentRecords: Array(records)
        )
    }
}

public enum LearningCoachError: Error, Equatable, Sendable {
    case configurationRequired
    case projectUnavailable
    case providerUnavailable
    case emptyResponse
}

extension LearningCoachError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configurationRequired: String(localized: "coach.error.configuration")
        case .projectUnavailable: String(localized: "coach.error.project")
        case .providerUnavailable: String(localized: "coach.error.provider")
        case .emptyResponse: String(localized: "coach.error.empty")
        }
    }
}

public protocol LearningCoachProviding: Sendable {
    func reply(
        context: LearningCoachContext,
        conversation: [LearningCoachTurn],
        question: String,
        attachments: [LearningCoachAttachment]
    ) async throws -> String
}

public struct AdaptiveLearningCoachProvider: LearningCoachProviding {
    private let settingsStore: AIReviewSettingsStore
    private let transport: any AIHTTPTransport

    public init(
        settingsStore: AIReviewSettingsStore = AIReviewSettingsStore(),
        transport: any AIHTTPTransport = URLSessionAIHTTPTransport()
    ) {
        self.settingsStore = settingsStore
        self.transport = transport
    }

    public func reply(
        context: LearningCoachContext,
        conversation: [LearningCoachTurn],
        question: String,
        attachments: [LearningCoachAttachment] = []
    ) async throws -> String {
        guard let settings = settingsStore.settings(),
              let apiKey = settingsStore.apiKey(),
              !apiKey.isEmpty else {
            throw LearningCoachError.configurationRequired
        }
        let request = LearningCoachRequest(
            context: context,
            conversation: Array(conversation.suffix(8)),
            question: question
        )
        let body = String(decoding: try JSONEncoder.journal.encode(request), as: UTF8.self)
        do {
            let response: LearningCoachResponse = try await OpenAICompatibleStructuredClient(
                settings: settings,
                apiKey: apiKey,
                transport: transport
            ).completeJSON(
                system: Self.systemPrompt,
                user: body,
                attachments: attachments.map(\.aiInput)
            )
            let answer = response.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw LearningCoachError.emptyResponse }
            return answer
        } catch let error as LearningCoachError {
            throw error
        } catch {
            throw LearningCoachError.providerUnavailable
        }
    }

    private static let systemPrompt = """
    You are a practical learning coach. Answer the learner's question using only the selected project's supplied goal, next step, plan phases, recent learning records, and the visible conversation. Never claim access to other journal data. Give concise, specific advice and distinguish observations from suggestions. If evidence is insufficient, ask one focused follow-up question. Match the language of the learner's latest question. Return one JSON object exactly shaped as {"reply":"..."}; do not wrap it in Markdown or add text outside the JSON.
    """
}

private struct LearningCoachRequest: Encodable {
    let context: LearningCoachContext
    let conversation: [LearningCoachTurn]
    let question: String
}

private struct LearningCoachResponse: Decodable {
    let reply: String
}
