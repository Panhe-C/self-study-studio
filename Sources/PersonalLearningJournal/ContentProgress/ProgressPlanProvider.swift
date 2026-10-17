import Foundation

public struct ProgressPlanInput: Sendable {
    public let name: String
    public let outlineText: String
    public let courseURL: String?

    public init(name: String, outlineText: String = "", courseURL: String? = nil) {
        self.name = name
        self.outlineText = outlineText
        self.courseURL = courseURL
    }
}

public enum ProgressPlanError: LocalizedError, Equatable, Sendable {
    case invalidName
    case outlineTooLong
    case unsafeEndpoint
    case linkNeedsReader
    case emptyUnits
    case invalidUnit
    case tooManyUnits

    public var errorDescription: String? {
        switch self {
        case .invalidName: "请先填写有效的项目名称。"
        case .outlineTooLong: "课程目录过长，请缩短后重试。"
        case .unsafeEndpoint: "AI 服务地址必须使用 HTTPS。"
        case .linkNeedsReader: "当前无法安全读取课程链接。请粘贴目录，或清除链接后按主题生成。"
        case .emptyUnits: "AI 未返回学习单元，请重试或手动添加。"
        case .invalidUnit: "AI 返回的学习单元标题无效，请重试。"
        case .tooManyUnits: "AI 返回的单元过多，请缩小主题或目录范围。"
        }
    }
}

public struct ProgressPlanProvider: Sendable {
    private let client: OpenAICompatibleStructuredClient
    private let endpoint: URL

    public init(
        settings: AIReviewSettings,
        apiKey: String,
        transport: (any AIHTTPTransport)? = nil
    ) {
        endpoint = settings.chatCompletionsURL
        client = OpenAICompatibleStructuredClient(
            settings: settings,
            apiKey: apiKey,
            transport: transport ?? ProgressPlanHTTPTransport()
        )
    }

    public func generate(_ input: ProgressPlanInput) async throws -> [String] {
        guard endpoint.scheme?.lowercased() == "https" else {
            throw ProgressPlanError.unsafeEndpoint
        }
        let name = ContentProgress.trimmed(input.name)
        guard !name.isEmpty,
              name.unicodeScalars.count <= ContentProgress.maximumProjectNameScalars else {
            throw ProgressPlanError.invalidName
        }
        let outline = ContentProgress.trimmed(input.outlineText)
        guard outline.utf8.count <= 30_000 else { throw ProgressPlanError.outlineTooLong }
        if outline.isEmpty, let link = input.courseURL, !ContentProgress.trimmed(link).isEmpty {
            throw ProgressPlanError.linkNeedsReader
        }

        let request = RequestInput(
            name: name,
            outlineText: outline.isEmpty ? nil : outline,
            source: outline.isEmpty ? "topic" : "pasted_outline"
        )
        let user = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let response: Response = try await client.completeJSON(system: Self.systemPrompt, user: user)
        guard !response.units.isEmpty else { throw ProgressPlanError.emptyUnits }
        guard response.units.count <= ContentProgress.maximumUnits else {
            throw ProgressPlanError.tooManyUnits
        }
        let titles = response.units.map { ContentProgress.trimmed($0.title) }
        guard titles.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= ContentProgress.maximumUnitTitleScalars }) else {
            throw ProgressPlanError.invalidUnit
        }
        return titles
    }

    private struct RequestInput: Encodable {
        let name: String
        let outlineText: String?
        let source: String
    }

    private struct Response: Decodable, Sendable {
        struct Unit: Decodable, Sendable {
            let title: String

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: AnyCodingKey.self)
                let key = AnyCodingKey("title")
                guard Set(container.allKeys.map(\.stringValue)) == Set(["title"]) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: container, debugDescription: "Unexpected unit field"
                    )
                }
                title = try container.decode(String.self, forKey: key)
            }
        }

        let units: [Unit]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            let key = AnyCodingKey("units")
            guard Set(container.allKeys.map(\.stringValue)) == Set(["units"]) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container, debugDescription: "Unexpected plan field"
                )
            }
            units = try container.decode([Unit].self, forKey: key)
        }
    }

    private struct AnyCodingKey: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int? = nil

        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static let systemPrompt = """
    You organize self-study content into a short ordered list. Return only JSON in this exact shape:
    {"units":[{"title":"..."}]}
    Use the supplied course outline when present; otherwise infer a sensible structure from the topic.
    Generate content units only. Do not include dates, durations, daily tasks, check-ins,
    notes, teaching, exercises, explanations, or any other fields.
    """
}

private struct ProgressPlanHTTPTransport: AIHTTPTransport {
    private let transport: URLSessionAIHTTPTransport

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        transport = URLSessionAIHTTPTransport(session: URLSession(configuration: configuration))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await transport.data(for: request)
    }
}
