import Foundation

public struct AIRequestArtifact: Equatable, Sendable {
    public var proofID: UUID
    public var mediaType: String?
    public var data: Data

    public init(proofID: UUID, mediaType: String?, data: Data) {
        self.proofID = proofID
        self.mediaType = mediaType
        self.data = data
    }
}

public struct AIRequestPackage: Equatable, Sendable {
    public var encodedText: String
    public var artifacts: [AIRequestArtifact]
    public var model: String
    public var sourceMetadata: [String: String]

    public init(
        encodedText: String,
        artifacts: [AIRequestArtifact],
        model: String,
        sourceMetadata: [String: String]
    ) {
        self.encodedText = encodedText
        self.artifacts = artifacts
        self.model = model
        self.sourceMetadata = sourceMetadata
    }
}

public struct AIRequestPackageBuilder: Sendable {
    public var model: String
    public var source: String

    public init(model: String, source: String = "Self Study Studio") {
        self.model = model
        self.source = source
    }

    public func makePackage(
        snapshot: JournalSnapshot,
        selectedProofIDs: Set<UUID>
    ) throws -> AIRequestPackage {
        let safeInput = SafeJournalAIInput(
            projects: snapshot.projects.map {
                .init(id: $0.id, name: $0.name, area: $0.area, goal: $0.goal, status: $0.status, currentNextStep: $0.currentNextStep)
            },
            sessions: snapshot.sessions.map {
                .init(id: $0.id, projectID: $0.projectId, actionType: $0.actionType, durationMinutes: $0.durationMinutes, note: $0.note)
            },
            proofs: snapshot.proofs.map {
                .init(id: $0.id, projectID: $0.projectId, type: $0.type, title: $0.title, statement: $0.statement)
            },
            plans: snapshot.coursePlans.map {
                .init(id: $0.id, projectID: $0.projectId, title: $0.courseTitle, summary: $0.summary)
            }
        )
        let data = try JSONEncoder.journal.encode(safeInput)
        let artifacts = try snapshot.proofs
            .filter { selectedProofIDs.contains($0.id) && $0.qualifies }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .compactMap(Self.authorizedArtifact)
        return AIRequestPackage(
            encodedText: String(decoding: data, as: UTF8.self),
            artifacts: artifacts,
            model: model,
            sourceMetadata: ["source": source, "authorization": "one-request"]
        )
    }

    private static func authorizedArtifact(_ proof: Proof) throws -> AIRequestArtifact? {
        guard let artifact = proof.artifact else { return nil }
        switch artifact {
        case let .text(markdown):
            return AIRequestArtifact(proofID: proof.id, mediaType: "text/markdown", data: Data(markdown.utf8))
        case let .attachment(localPath, mimeType, _):
            guard FileManager.default.isReadableFile(atPath: localPath) else { return nil }
            return AIRequestArtifact(
                proofID: proof.id,
                mediaType: mimeType,
                data: try Data(contentsOf: URL(fileURLWithPath: localPath))
            )
        case let .link(url, _, _, _, _, snapshotPath):
            if let snapshotPath, FileManager.default.isReadableFile(atPath: snapshotPath) {
                return AIRequestArtifact(
                    proofID: proof.id,
                    mediaType: proof.mimeType,
                    data: try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
                )
            }
            return AIRequestArtifact(proofID: proof.id, mediaType: "text/uri-list", data: Data(url.absoluteString.utf8))
        }
    }
}

private struct SafeJournalAIInput: Codable {
    struct ProjectInput: Codable {
        var id: UUID
        var name: String
        var area: String
        var goal: String
        var status: ProjectStatus
        var currentNextStep: String
    }
    struct SessionInput: Codable {
        var id: UUID
        var projectID: UUID
        var actionType: ActionType
        var durationMinutes: Int
        var note: String
    }
    struct ProofInput: Codable {
        var id: UUID
        var projectID: UUID
        var type: ProofType
        var title: String
        var statement: String
    }
    struct PlanInput: Codable {
        var id: UUID
        var projectID: UUID
        var title: String
        var summary: String
    }
    var projects: [ProjectInput]
    var sessions: [SessionInput]
    var proofs: [ProofInput]
    var plans: [PlanInput]
}

public protocol AIHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionAIHTTPTransport: AIHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public struct OpenAICompatibleStructuredClient: Sendable {
    private let settings: AIReviewSettings
    private let apiKey: String
    private let transport: any AIHTTPTransport

    public init(
        settings: AIReviewSettings,
        apiKey: String,
        transport: any AIHTTPTransport = URLSessionAIHTTPTransport()
    ) {
        self.settings = settings
        self.apiKey = apiKey
        self.transport = transport
    }

    public func completeJSON<Response: Decodable & Sendable>(
        system: String,
        user: String,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        var request = URLRequest(url: settings.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.journal.encode(
            ChatCompletionsRequest(
                model: settings.model,
                messages: [
                    .init(role: "system", content: system),
                    .init(role: "user", content: user)
                ],
                responseFormat: .init(type: "json_object")
            )
        )

        let (data, response) = try await transport.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        let completion = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let content = completion.choices.first?.message.content,
              let resultData = content.data(using: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return try JSONDecoder.journal.decode(Response.self, from: resultData)
    }
}

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }
    struct ResponseFormat: Encodable {
        var type: String
        enum CodingKeys: String, CodingKey { case type }
    }
    var model: String
    var messages: [Message]
    var responseFormat: ResponseFormat
    enum CodingKeys: String, CodingKey {
        case model, messages
        case responseFormat = "response_format"
    }
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message
    }
    var choices: [Choice]
}
