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

@available(*, deprecated, renamed: "AIHTTPTransport")
public typealias ReviewHTTPTransport = AIHTTPTransport

@available(*, deprecated, renamed: "URLSessionAIHTTPTransport")
public typealias URLSessionReviewHTTPTransport = URLSessionAIHTTPTransport

public struct OpenAICompatibleReviewProvider: AIReviewProvider {
    private let client: OpenAICompatibleStructuredClient

    public init(
        settings: AIReviewSettings,
        apiKey: String,
        transport: any AIHTTPTransport = URLSessionAIHTTPTransport()
    ) {
        self.client = OpenAICompatibleStructuredClient(
            settings: settings,
            apiKey: apiKey,
            transport: transport
        )
    }

    public func makeReview(
        snapshot: JournalSnapshot,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> ReviewDraft {
        let response: OpenAIReviewDraftPayload = try await client.completeJSON(
            system: Self.systemPrompt,
            user: try Self.reviewInput(
                snapshot: snapshot,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        )
        return response.reviewDraft
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

private struct OpenAIReviewDraftPayload: Decodable, Sendable {
    var facts: [String]
    var patterns: [String]
    var decisions: [String]
    var projectRecommendations: [String: String]
    var nextSteps: [String: String]
    var sourceSummary: [String]
    var sourceReferences: [String: [String]]?

    var reviewDraft: ReviewDraft {
        var references = sourceReferences ?? [:]
        for insight in facts + patterns + decisions where references[insight, default: []].isEmpty {
            references[insight] = sourceSummary
        }
        return ReviewDraft(
            facts: facts,
            patterns: patterns,
            decisions: decisions,
            projectRecommendations: projectRecommendations.reduce(into: [:]) { result, item in
                guard let id = UUID(uuidString: item.key), let status = ProjectStatus(rawValue: item.value) else { return }
                result[id] = status
            },
            nextSteps: nextSteps.reduce(into: [:]) { result, item in
                guard let id = UUID(uuidString: item.key) else { return }
                result[id] = item.value
            },
            sourceSummary: sourceSummary,
            sourceReferences: references
        )
    }
}

public struct AdaptiveAIReviewProvider: AIReviewProvider {
    private let settingsStore: AIReviewSettingsStore
    private let transport: any AIHTTPTransport
    private let fallback: any AIReviewProvider

    public init(
        settingsStore: AIReviewSettingsStore = AIReviewSettingsStore(),
        transport: any AIHTTPTransport = URLSessionAIHTTPTransport(),
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
