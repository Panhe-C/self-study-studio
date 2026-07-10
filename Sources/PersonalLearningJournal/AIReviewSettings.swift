import Foundation

#if canImport(Security)
import Security
#endif

public struct AIReviewSettings: Codable, Equatable, Sendable {
    public var endpoint: URL
    public var model: String

    public init(endpoint: URL, model: String) {
        self.endpoint = endpoint
        self.model = model
    }

    public var chatCompletionsURL: URL {
        if endpoint.path.hasSuffix("/chat/completions") {
            return endpoint
        }
        return endpoint.appendingPathComponent("chat/completions")
    }
}

public enum AIReviewSettingsError: Error, Equatable, Sendable {
    case invalidEndpoint
    case emptyModel
    case keychainFailure(OSStatus)
}

public protocol APIKeyStore: Sendable {
    func value(for key: String) throws -> String?
    func setValue(_ value: String?, for key: String) throws
}

public final class KeychainAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.local.selfstudystudio") {
        self.service = service
    }

    public func value(for key: String) throws -> String? {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AIReviewSettingsError.keychainFailure(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    public func setValue(_ value: String?, for key: String) throws {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AIReviewSettingsError.keychainFailure(status)
            }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var createQuery = query
            createQuery[kSecValueData] = data
            let addStatus = SecItemAdd(createQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AIReviewSettingsError.keychainFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw AIReviewSettingsError.keychainFailure(updateStatus)
        }
        #endif
    }
}

public final class AIReviewSettingsStore: @unchecked Sendable {
    private enum Keys {
        static let settings = "aiReviewSettings"
        static let apiKey = "aiReviewAPIKey"
    }

    private let userDefaults: UserDefaults
    private let keyStore: any APIKeyStore

    public init(
        userDefaults: UserDefaults = .standard,
        keyStore: any APIKeyStore = KeychainAPIKeyStore()
    ) {
        self.userDefaults = userDefaults
        self.keyStore = keyStore
    }

    public func settings() -> AIReviewSettings? {
        guard let data = userDefaults.data(forKey: Keys.settings) else { return nil }
        return try? JSONDecoder().decode(AIReviewSettings.self, from: data)
    }

    public func apiKey() -> String? {
        try? keyStore.value(for: Keys.apiKey)
    }

    public func save(settings: AIReviewSettings, apiKey: String?) throws {
        guard let scheme = settings.endpoint.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw AIReviewSettingsError.invalidEndpoint
        }
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIReviewSettingsError.emptyModel
        }

        let data = try JSONEncoder().encode(settings)
        userDefaults.set(data, forKey: Keys.settings)
        if let apiKey {
            try keyStore.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keys.apiKey)
        }
    }

    public func clearAPIKey() throws {
        try keyStore.setValue(nil, for: Keys.apiKey)
    }

    public var isConfigured: Bool {
        settings() != nil && !(apiKey()?.isEmpty ?? true)
    }
}

public protocol ReviewHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionReviewHTTPTransport: ReviewHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public struct OpenAICompatibleReviewProvider: AIReviewProvider {
    private let settings: AIReviewSettings
    private let apiKey: String
    private let transport: any ReviewHTTPTransport

    public init(
        settings: AIReviewSettings,
        apiKey: String,
        transport: any ReviewHTTPTransport = URLSessionReviewHTTPTransport()
    ) {
        self.settings = settings
        self.apiKey = apiKey
        self.transport = transport
    }

    public func makeReview(
        snapshot: JournalSnapshot,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> ReviewDraft {
        var request = URLRequest(url: settings.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.journal.encode(
            OpenAICompatibleReviewRequest(
                model: settings.model,
                messages: [
                    .init(role: "system", content: Self.systemPrompt),
                    .init(
                        role: "user",
                        content: try Self.reviewInput(
                            snapshot: snapshot,
                            periodStart: periodStart,
                            periodEnd: periodEnd
                        )
                    )
                ],
                responseFormat: .init(type: "json_object")
            )
        )

        let (data, response) = try await transport.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode)
        {
            throw URLError(.badServerResponse)
        }

        let completion = try JSONDecoder().decode(OpenAICompatibleReviewResponse.self, from: data)
        guard let content = completion.choices.first?.message.content,
              let resultData = content.data(using: .utf8)
        else {
            throw URLError(.cannotParseResponse)
        }
        return try HTTPAIReviewProvider.decodeDraft(from: resultData)
    }

    private static let systemPrompt = """
    You are a calm personal learning-review assistant. Return only a JSON object with facts, patterns, decisions, projectRecommendations, nextSteps, sourceSummary, and sourceReferences. Use no more than three facts, patterns, or decisions. Every generated insight must cite concrete session or Proof summaries in sourceReferences. Never change project status yourself and do not use motivational or streak language.
    """

    private static func reviewInput(
        snapshot: JournalSnapshot,
        periodStart: Date,
        periodEnd: Date
    ) throws -> String {
        let input = OpenAICompatibleReviewInput(
            periodStart: periodStart,
            periodEnd: periodEnd,
            projects: snapshot.projects,
            sessions: snapshot.sessions,
            proofs: snapshot.proofs
        )
        return String(decoding: try JSONEncoder.journal.encode(input), as: UTF8.self)
    }
}

public struct AdaptiveAIReviewProvider: AIReviewProvider {
    private let settingsStore: AIReviewSettingsStore
    private let transport: any ReviewHTTPTransport
    private let fallback: any AIReviewProvider

    public init(
        settingsStore: AIReviewSettingsStore = AIReviewSettingsStore(),
        transport: any ReviewHTTPTransport = URLSessionReviewHTTPTransport(),
        fallback: any AIReviewProvider = RuleBasedReviewProvider()
    ) {
        self.settingsStore = settingsStore
        self.transport = transport
        self.fallback = fallback
    }

    public func makeReview(
        snapshot: JournalSnapshot,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> ReviewDraft {
        guard let settings = settingsStore.settings(),
              let apiKey = settingsStore.apiKey(),
              !apiKey.isEmpty
        else {
            return try await fallback.makeReview(
                snapshot: snapshot,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        }

        do {
            return try await OpenAICompatibleReviewProvider(
                settings: settings,
                apiKey: apiKey,
                transport: transport
            ).makeReview(
                snapshot: snapshot,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        } catch {
            return try await fallback.makeReview(
                snapshot: snapshot,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        }
    }
}

private struct OpenAICompatibleReviewRequest: Encodable {
    var model: String
    var messages: [Message]
    var responseFormat: ResponseFormat
    var temperature = 0.2

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case temperature
    }

    struct Message: Encodable {
        var role: String
        var content: String
    }

    struct ResponseFormat: Encodable {
        var type: String
    }
}

private struct OpenAICompatibleReviewInput: Codable {
    var periodStart: Date
    var periodEnd: Date
    var projects: [Project]
    var sessions: [LearningSession]
    var proofs: [Proof]
}

private struct OpenAICompatibleReviewResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: Message
    }

    struct Message: Decodable {
        var content: String?
    }
}
