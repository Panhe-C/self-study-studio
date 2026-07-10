import Foundation

public struct ReviewDraft: Equatable, Sendable {
    public var facts: [String]
    public var patterns: [String]
    public var decisions: [String]
    public var projectRecommendations: [UUID: ProjectStatus]
    public var nextSteps: [UUID: String]
    public var sourceSummary: [String]
    public var sourceReferences: [String: [String]]

    public init(
        facts: [String],
        patterns: [String],
        decisions: [String],
        projectRecommendations: [UUID: ProjectStatus],
        nextSteps: [UUID: String],
        sourceSummary: [String],
        sourceReferences: [String: [String]] = [:]
    ) {
        self.facts = facts
        self.patterns = patterns
        self.decisions = decisions
        self.projectRecommendations = projectRecommendations
        self.nextSteps = nextSteps
        self.sourceSummary = sourceSummary
        self.sourceReferences = sourceReferences
    }
}

public protocol AIReviewProvider: Sendable {
    func makeReview(
        snapshot: JournalSnapshot,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> ReviewDraft
}

public struct RuleBasedReviewProvider: AIReviewProvider {
    public init() {}

    public func makeReview(
        snapshot: JournalSnapshot,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> ReviewDraft {
        let periodSessions = snapshot.sessions.filter {
            $0.endedAt >= periodStart && $0.endedAt <= periodEnd
        }
        let periodProofs = snapshot.proofs.filter {
            $0.createdAt >= periodStart && $0.createdAt <= periodEnd
        }
        var facts: [String] = []
        var patterns: [String] = []
        var decisions: [String] = []
        var recommendations: [UUID: ProjectStatus] = [:]
        var nextSteps: [UUID: String] = [:]
        var sources: [String] = []
        var sourceReferences: [String: [String]] = [:]

        for project in snapshot.projects where project.status == .active {
            let projectSessions = periodSessions.filter { $0.projectId == project.id }
            let projectProofs = periodProofs.filter { $0.projectId == project.id }
            if projectSessions.isEmpty && projectProofs.isEmpty {
                let lastActivity = latestActivityDate(for: project, in: snapshot)
                if periodEnd.timeIntervalSince(lastActivity) >= 7 * 24 * 60 * 60 {
                    let activitySource = "project \(project.id.uuidString.prefix(8)): no session or Proof recorded in this period"
                    let fact = "\(project.name): no sessions or Proofs in this period."
                    let pattern = "\(project.name) has gone quiet for at least 7 days."
                    let decision = "\(project.name): Create one small Proof or lower to low-frequency."
                    facts.append(fact)
                    patterns.append(pattern)
                    decisions.append(decision)
                    sourceReferences[fact] = [activitySource]
                    sourceReferences[pattern] = [activitySource]
                    sourceReferences[decision] = [activitySource]
                    nextSteps[project.id] = "Choose one small Proof or lower this project for the week"
                    recommendations[project.id] = .lowFrequency
                }
                continue
            }

            let minutes = projectSessions.reduce(0) { $0 + $1.durationMinutes }
            let projectSources = projectSessions.map { "session \($0.id.uuidString.prefix(8)): \($0.note)" }
                + projectProofs.map { "proof \($0.id.uuidString.prefix(8)): \($0.statement)" }
            let fact = "\(project.name): \(projectSessions.count) sessions, \(projectProofs.count) Proofs, \(minutes) min."
            facts.append(fact)
            sourceReferences[fact] = projectSources
            sources.append(contentsOf: projectSources)

            if projectSessions.count >= 2 && projectProofs.isEmpty {
                let pattern = "\(project.name) has repeated input with no Proof."
                let decision = "\(project.name): Create one output Proof and do not watch new lecture."
                patterns.append(pattern)
                decisions.append(decision)
                sourceReferences[pattern] = projectSources
                sourceReferences[decision] = projectSources
                nextSteps[project.id] = "Create one output Proof before new input"
                recommendations[project.id] = .active
            } else if projectProofs.isEmpty {
                let pattern = "\(project.name) has activity but no Proof yet."
                let decision = "\(project.name): Add one Proof before expanding scope."
                patterns.append(pattern)
                decisions.append(decision)
                sourceReferences[pattern] = projectSources
                sourceReferences[decision] = projectSources
                nextSteps[project.id] = project.currentNextStep
                recommendations[project.id] = .active
            } else {
                let pattern = "\(project.name) has learning evidence attached to the trail."
                let decision = "\(project.name): Continue with the current Next Step."
                patterns.append(pattern)
                decisions.append(decision)
                sourceReferences[pattern] = projectSources
                sourceReferences[decision] = projectSources
                nextSteps[project.id] = project.currentNextStep
                recommendations[project.id] = .active
            }
        }

        if facts.isEmpty {
            let activitySource = "No session or Proof was recorded in this period."
            let fact = "No sessions or Proofs were recorded in this period."
            let pattern = "No reliable learning pattern can be inferred yet."
            let decision = "Record one session with one Proof before the next review."
            facts = [fact]
            patterns = [pattern]
            decisions = [decision]
            sourceReferences[fact] = [activitySource]
            sourceReferences[pattern] = [activitySource]
            sourceReferences[decision] = [activitySource]
        }

        let selectedFacts = Array(facts.prefix(3))
        let selectedPatterns = Array(patterns.prefix(3))
        let selectedDecisions = Array(decisions.prefix(3))
        let selectedInsights = Set(selectedFacts + selectedPatterns + selectedDecisions)

        return ReviewDraft(
            facts: selectedFacts,
            patterns: selectedPatterns,
            decisions: selectedDecisions,
            projectRecommendations: recommendations,
            nextSteps: nextSteps,
            sourceSummary: Array(sources.prefix(12)),
            sourceReferences: sourceReferences.filter { selectedInsights.contains($0.key) }
        )
    }

    private func latestActivityDate(for project: Project, in snapshot: JournalSnapshot) -> Date {
        let lastSessionDate = snapshot.sessions
            .filter { $0.projectId == project.id }
            .map(\.endedAt)
            .max()
        let lastProofDate = snapshot.proofs
            .filter { $0.projectId == project.id }
            .map(\.createdAt)
            .max()

        return [
            project.updatedAt,
            lastSessionDate,
            lastProofDate
        ].compactMap { $0 }.max() ?? project.createdAt
    }
}

public final class HTTPAIReviewProvider: AIReviewProvider, @unchecked Sendable {
    private let endpoint: URL
    private let apiKey: String?
    private let timeoutSeconds: TimeInterval
    private let session: URLSession

    public init(
        endpoint: URL,
        apiKey: String? = nil,
        timeoutSeconds: TimeInterval = 20,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
        self.session = session
    }

    public func makeReview(
        snapshot: JournalSnapshot,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> ReviewDraft {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder.journal.encode(
            HTTPAIReviewRequest(
                periodStart: periodStart,
                periodEnd: periodEnd,
                projects: snapshot.projects,
                sessions: snapshot.sessions,
                proofs: snapshot.proofs
            )
        )

        let (data, response) = try await session.data(for: request)
        if
            let httpResponse = response as? HTTPURLResponse,
            !(200...299).contains(httpResponse.statusCode)
        {
            throw URLError(.badServerResponse)
        }
        return try Self.decodeDraft(from: data)
    }

    public static func decodeDraft(from data: Data) throws -> ReviewDraft {
        let response = try JSONDecoder.journal.decode(HTTPAIReviewResponse.self, from: data)
        var sourceReferences = response.sourceReferences ?? [:]
        if !response.sourceSummary.isEmpty {
            for insight in response.facts + response.patterns + response.decisions
            where sourceReferences[insight, default: []].isEmpty {
                sourceReferences[insight] = response.sourceSummary
            }
        }
        return ReviewDraft(
            facts: response.facts,
            patterns: response.patterns,
            decisions: response.decisions,
            projectRecommendations: response.projectRecommendations.compactMapKeys(UUID.init)
                .compactMapValues(ProjectStatus.init(rawValue:)),
            nextSteps: response.nextSteps.compactMapKeys(UUID.init),
            sourceSummary: response.sourceSummary,
            sourceReferences: sourceReferences
        )
    }

}

@MainActor
public final class ReviewService {
    private let journalService: JournalService
    private let provider: any AIReviewProvider
    private let now: () -> Date

    public init(
        journalService: JournalService,
        provider: any AIReviewProvider = RuleBasedReviewProvider(),
        now: @escaping () -> Date = Date.init
    ) {
        self.journalService = journalService
        self.provider = provider
        self.now = now
    }

    @discardableResult
    public func createWeeklyReview(
        periodStart: Date,
        periodEnd: Date
    ) async throws -> Review {
        let draft: ReviewDraft
        do {
            draft = try await provider.makeReview(
                snapshot: journalService.snapshot(),
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        } catch {
            draft = ReviewDraft(
                facts: ["AI review unavailable; create a manual weekly review."],
                patterns: ["Manual review needed."],
                decisions: ["Choose one project to continue, lower, or pause."],
                projectRecommendations: [:],
                nextSteps: [:],
                sourceSummary: [],
                sourceReferences: [:]
            )
        }

        let createdAt = now()
        let review = Review(
            periodStart: periodStart,
            periodEnd: periodEnd,
            facts: draft.facts,
            patterns: draft.patterns,
            decisions: draft.decisions,
            projectRecommendations: draft.projectRecommendations,
            nextSteps: draft.nextSteps,
            aiSourceSummary: draft.sourceSummary,
            sourceReferences: draft.sourceReferences,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        try journalService.recordReview(review)
        return review
    }
}

private struct HTTPAIReviewRequest: Codable {
    var periodStart: Date
    var periodEnd: Date
    var projects: [Project]
    var sessions: [LearningSession]
    var proofs: [Proof]
}

private struct HTTPAIReviewResponse: Codable {
    var facts: [String]
    var patterns: [String]
    var decisions: [String]
    var projectRecommendations: [String: String]
    var nextSteps: [String: String]
    var sourceSummary: [String]
    var sourceReferences: [String: [String]]?
}

private extension Dictionary where Key == String {
    func compactMapKeys<T: Hashable>(_ transform: (String) -> T?) -> [T: Value] {
        reduce(into: [T: Value]()) { partialResult, item in
            guard let key = transform(item.key) else { return }
            partialResult[key] = item.value
        }
    }
}
