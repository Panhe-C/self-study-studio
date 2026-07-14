import Foundation

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
