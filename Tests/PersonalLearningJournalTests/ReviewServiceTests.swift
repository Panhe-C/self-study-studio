import XCTest
@testable import PersonalLearningJournal

@MainActor
final class ReviewServiceTests: XCTestCase {
    func testRuleBasedReviewIsSourcedButDecisionFree() async throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "写 notebook"
        )
        _ = try service.quickLog(
            projectId: project.id,
            durationMinutes: 30,
            note: "看完 Lecture 1"
        )
        let review = try await ReviewService(
            journalService: service,
            provider: RuleBasedReviewProvider()
        ).createWeeklyReview(periodStart: .distantPast, periodEnd: .distantFuture)
        let pattern = try XCTUnwrap(review.patterns.first)

        XCTAssertTrue(review.decisions.isEmpty)
        XCTAssertFalse(review.sourceReferences[pattern, default: []].isEmpty)
    }

    func testApplyingReviewRecommendationChangesStatusOnlyAfterExplicitAction() async throws {
        let referenceDate = Date(timeIntervalSince1970: 10_000_000)
        let service = JournalService(
            store: InMemoryJournalStore(),
            now: { referenceDate.addingTimeInterval(-8 * 24 * 60 * 60) }
        )
        let project = try service.createProject(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )
        let reviewService = ReviewService(
            journalService: service,
            provider: RuleBasedReviewProvider(),
            now: { referenceDate }
        )
        let review = try await reviewService.createWeeklyReview(
            periodStart: referenceDate.addingTimeInterval(-7 * 24 * 60 * 60),
            periodEnd: referenceDate
        )

        XCTAssertEqual(service.project(id: project.id)?.status, .active)

        try service.applyReviewRecommendation(reviewId: review.id, projectId: project.id)

        XCTAssertEqual(service.project(id: project.id)?.status, .lowFrequency)
    }

    func testRuleBasedWeeklyReviewProducesFactPatternDecisionAndNextStep() async throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "看 Lecture 1"
        )
        _ = try service.quickLog(
            projectId: project.id,
            actionType: .course,
            durationMinutes: 45,
            note: "看完 Lecture 1",
            nextStep: "整理 perplexity"
        )
        _ = try service.quickLog(
            projectId: project.id,
            actionType: .reading,
            durationMinutes: 40,
            note: "读课程 notes",
            nextStep: "整理 perplexity"
        )
        _ = try service.quickLog(
            projectId: project.id,
            actionType: .course,
            durationMinutes: 50,
            note: "看完 Lecture 2",
            nextStep: "整理 perplexity"
        )

        let reviewService = ReviewService(
            journalService: service,
            provider: RuleBasedReviewProvider()
        )
        let review = try await reviewService.createWeeklyReview(
            periodStart: .distantPast,
            periodEnd: .distantFuture
        )

        XCTAssertTrue(review.facts.joined(separator: " ").contains("CS336"))
        XCTAssertTrue(review.patterns.joined(separator: " ").contains("Proof"))
        XCTAssertTrue(review.decisions.isEmpty)
        XCTAssertEqual(review.nextSteps[project.id], "Create one output Proof before new input")
        XCTAssertTrue(review.aiSourceSummary.contains { $0.contains("session") })
    }

    func testRuleBasedWeeklyReviewRecommendsLowFrequencyForIdleActiveProject() async throws {
        let referenceDate = Date(timeIntervalSince1970: 10_000_000)
        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            currentNextStep: "练第一段",
            createdAt: referenceDate.addingTimeInterval(-14 * 24 * 60 * 60),
            updatedAt: referenceDate.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        let snapshot = JournalSnapshot(projects: [project])

        let draft = try await RuleBasedReviewProvider().makeReview(
            snapshot: snapshot,
            periodStart: referenceDate.addingTimeInterval(-7 * 24 * 60 * 60),
            periodEnd: referenceDate
        )

        XCTAssertEqual(draft.projectRecommendations[project.id], .lowFrequency)
        XCTAssertEqual(draft.nextSteps[project.id], "Choose one small Proof or lower this project for the week")
        XCTAssertTrue(draft.facts.joined(separator: " ").contains("no sessions or Proofs"))
        XCTAssertTrue(draft.decisions.isEmpty)
    }

    func testHTTPAIReviewProviderDecodesDraftResponse() throws {
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let data = Data(
            """
            {
              "facts": ["CS336: 3 sessions, 1 Proof."],
              "patterns": ["Input is now paired with output."],
              "decisions": ["Continue CS336 with one notebook."],
              "projectRecommendations": {
                "\(projectId.uuidString)": "active"
              },
              "nextSteps": {
                "\(projectId.uuidString)": "Write the loss note"
              },
              "sourceSummary": ["session abc: 看完 Lecture 1", "proof def: Bigram notebook"]
            }
            """.utf8
        )

        let draft = try HTTPAIReviewProvider.decodeDraft(from: data)

        XCTAssertEqual(draft.facts, ["CS336: 3 sessions, 1 Proof."])
        XCTAssertEqual(draft.patterns, ["Input is now paired with output."])
        XCTAssertTrue(draft.decisions.isEmpty)
        XCTAssertEqual(draft.projectRecommendations[projectId], .active)
        XCTAssertEqual(draft.nextSteps[projectId], "Write the loss note")
        XCTAssertEqual(draft.sourceSummary.count, 2)
    }

    func testOpenAICompatibleProviderParsesJSONContentFromChatCompletion() async throws {
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let completionData = Data(
            """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\\"facts\\\":[\\\"CS336: 1 session.\\\"],\\\"patterns\\\":[\\\"Input needs an output Proof.\\\"],\\\"decisions\\\":[\\\"Create one notebook.\\\"],\\\"projectRecommendations\\\":{\\\"\(projectId.uuidString)\\\":\\\"active\\\"},\\\"nextSteps\\\":{\\\"\(projectId.uuidString)\\\":\\\"Write the loss note\\\"},\\\"sourceSummary\\\":[\\\"session abc: Lecture 1\\\"]}"
                  }
                }
              ]
            }
            """.utf8
        )
        let provider = OpenAICompatibleReviewProvider(
            settings: AIReviewSettings(
                endpoint: URL(string: "https://example.test/v1")!,
                model: "test-model"
            ),
            apiKey: "test-key",
            transport: StubReviewHTTPTransport(data: completionData)
        )

        let draft = try await provider.makeReview(
            snapshot: JournalSnapshot(),
            periodStart: .distantPast,
            periodEnd: .distantFuture
        )

        XCTAssertEqual(draft.facts, ["CS336: 1 session."])
        XCTAssertEqual(draft.nextSteps[projectId], "Write the loss note")
        XCTAssertNil(draft.sourceReferences["Create one notebook."])
    }

    func testLinkedPracticeAppearsInProjectHistoryAndRuleBasedReviewSources() async throws {
        let repository = InMemoryJournalRepository()
        let journalService = JournalService(repository: repository)
        let practiceService = PracticeService(repository: repository)
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            practiceService: practiceService,
            practiceTimer: PracticeTimerRuntime(store: ReviewPracticeTimerStateStore())
        )
        let project = try viewModel.createProject(
            name: "Guitar Project",
            area: "Music",
            goal: "Play cleanly",
            nextStep: "Practice scales"
        )
        let routine = try viewModel.createPracticeRoutine(
            projectId: project.id,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        let completion = PracticeTimerCompletion(
            routineId: routine.id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_800),
            activeDurationSeconds: 1_800
        )
        let saved = try viewModel.savePracticeCompletion(
            completion,
            linkedProjectId: project.id,
            note: "Scales"
        )
        let reviewService = ReviewService(
            journalService: journalService,
            provider: RuleBasedReviewProvider()
        )

        let review = try await reviewService.createWeeklyReview(
            periodStart: Date(timeIntervalSince1970: 900),
            periodEnd: Date(timeIntervalSince1970: 3_000)
        )

        XCTAssertEqual(viewModel.practiceSessionsForProject(project.id).map(\.id), [saved.session.id])
        XCTAssertEqual(viewModel.sessions.map(\.id), [saved.learningSession.id])
        XCTAssertTrue(review.facts.contains { $0.contains("30 min") })
        XCTAssertTrue(
            review.aiSourceSummary.contains(
                "session \(saved.learningSession.id.uuidString.prefix(8)): Scales"
            )
        )
        XCTAssertFalse(review.aiSourceSummary.contains { $0.hasPrefix("practice \(saved.session.id.uuidString.prefix(8))") })
    }

    func testStructuredReviewInputIncludesOnlyLinkedPracticeInPeriod() async throws {
        let project = Project(
            name: "Guitar Project",
            area: "Music",
            goal: "Play cleanly",
            currentNextStep: "Practice scales"
        )
        let routine = PracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        let linked = PracticeSession(
            routineId: routine.id,
            linkedProjectId: project.id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_800),
            activeDurationSeconds: 1_800,
            note: nil
        )
        let unlinked = PracticeSession(
            routineId: routine.id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_600),
            activeDurationSeconds: 600,
            note: "Unlinked"
        )
        let outsidePeriod = PracticeSession(
            routineId: routine.id,
            linkedProjectId: project.id,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 700),
            activeDurationSeconds: 600,
            note: "Outside"
        )
        let deleted = PracticeSession(
            routineId: routine.id,
            linkedProjectId: project.id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_600),
            activeDurationSeconds: 600,
            note: "Deleted",
            deletedAt: Date(timeIntervalSince1970: 2_000)
        )
        let transport = CapturingReviewHTTPTransport()
        let provider = OpenAICompatibleReviewProvider(
            settings: AIReviewSettings(
                endpoint: URL(string: "https://example.test/v1")!,
                model: "test-model"
            ),
            apiKey: "test-key",
            transport: transport
        )

        _ = try await provider.makeReview(
            snapshot: JournalSnapshot(
                projects: [project],
                practiceRoutines: [routine],
                practiceSessions: [linked, unlinked, outsidePeriod, deleted]
            ),
            periodStart: Date(timeIntervalSince1970: 900),
            periodEnd: Date(timeIntervalSince1970: 3_000)
        )

        let reviewInput = try XCTUnwrap(transport.reviewInput())
        let practiceSessions = try XCTUnwrap(reviewInput["practiceSessions"] as? [[String: Any]])
        let practiceSources = try XCTUnwrap(reviewInput["practiceSources"] as? [String])
        XCTAssertEqual(practiceSessions.count, 1)
        XCTAssertEqual(practiceSessions[0]["id"] as? String, linked.id.uuidString)
        XCTAssertEqual(
            practiceSources,
            ["practice \(linked.id.uuidString.prefix(8)): 30 min - Guitar"]
        )
    }

    func testAIReviewSettingsStoreKeepsAPIKeyOutsideRegularSettings() throws {
        let suiteName = "PersonalLearningJournalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keyStore = TestAPIKeyStore()
        let store = AIReviewSettingsStore(userDefaults: defaults, keyStore: keyStore)
        let settings = AIReviewSettings(
            endpoint: try XCTUnwrap(URL(string: "https://example.test/v1")),
            model: "test-model"
        )

        try store.save(settings: settings, apiKey: "secret-key")

        XCTAssertEqual(store.settings(), settings)
        XCTAssertEqual(store.apiKey(), "secret-key")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains("secret-key") })
    }

    func testAdaptiveProviderUsesLocalReviewWhenAIIsNotConfigured() async throws {
        let suiteName = "PersonalLearningJournalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIReviewSettingsStore(userDefaults: defaults, keyStore: TestAPIKeyStore())
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            currentNextStep: "写 notebook"
        )
        let draft = try await AdaptiveAIReviewProvider(settingsStore: store).makeReview(
            snapshot: JournalSnapshot(projects: [project]),
            periodStart: .distantPast,
            periodEnd: .distantFuture
        )

        XCTAssertTrue(draft.decisions.isEmpty)
    }

    func testReviewServiceFallsBackToManualReviewWhenProviderFails() async throws {
        let service = JournalService(store: InMemoryJournalStore())
        _ = try service.createProject(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )

        let reviewService = ReviewService(
            journalService: service,
            provider: FailingReviewProvider()
        )
        let review = try await reviewService.createWeeklyReview(
            periodStart: .distantPast,
            periodEnd: .distantFuture
        )

        XCTAssertEqual(review.facts, ["AI review unavailable; create a manual weekly review."])
        XCTAssertEqual(review.patterns, ["Manual review needed."])
        XCTAssertTrue(review.decisions.isEmpty)
        XCTAssertTrue(review.nextSteps.isEmpty)
    }

    func testReviewIsPersistedAndAppearsInTrail() async throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createProject(
            name: "DaVinci",
            area: "Color",
            goal: "掌握基础调色工作流",
            nextStep: "做一组 before/after"
        )
        _ = try service.quickLog(
            projectId: project.id,
            actionType: .practice,
            durationMinutes: 30,
            note: "调了一组白平衡",
            nextStep: "继续做肤色练习"
        )
        _ = try service.addProof(
            projectId: project.id,
            type: .image,
            title: "before/after",
            statement: "证明能控制白平衡，但肤色偏红"
        )

        let reviewService = ReviewService(
            journalService: service,
            provider: RuleBasedReviewProvider()
        )
        let review = try await reviewService.createWeeklyReview(
            periodStart: .distantPast,
            periodEnd: .distantFuture
        )

        XCTAssertEqual(service.snapshot().reviews.map(\.id), [review.id])
        XCTAssertTrue(service.trailEvents(projectId: project.id).contains { $0.type == .review })
    }

    func testReviewCanBeEditedWhileKeepingAISources() throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createProject(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )
        let review = Review(
            periodStart: .distantPast,
            periodEnd: .distantFuture,
            facts: ["Original fact"],
            patterns: ["Original pattern"],
            decisions: ["Original decision"],
            projectRecommendations: [project.id: .active],
            nextSteps: [project.id: "Original next"],
            aiSourceSummary: ["session abc: 练第一段"]
        )
        try service.recordReview(review)

        let updated = try service.updateReview(
            reviewId: review.id,
            facts: ["Edited fact"],
            patterns: ["Edited pattern"],
            decisions: ["Edited decision"],
            nextSteps: [project.id: "Edited next"]
        )

        XCTAssertEqual(updated.facts, ["Edited fact"])
        XCTAssertEqual(updated.patterns, ["Edited pattern"])
        XCTAssertEqual(updated.decisions, ["Edited decision"])
        XCTAssertEqual(updated.nextSteps[project.id], "Edited next")
        XCTAssertEqual(updated.projectRecommendations[project.id], .active)
        XCTAssertEqual(updated.aiSourceSummary, ["session abc: 练第一段"])
        XCTAssertEqual(service.snapshot().reviews.first, updated)
    }
}

private struct FailingReviewProvider: AIReviewProvider {
    func makeReview(
        snapshot: JournalSnapshot,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> ReviewDraft {
        throw NSError(domain: "test", code: 1)
    }
}

private struct StubReviewHTTPTransport: AIHTTPTransport {
    let data: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

private final class TestAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func value(for key: String) throws -> String? {
        values[key]
    }

    func setValue(_ value: String?, for key: String) throws {
        values[key] = value
    }
}

@MainActor
private final class ReviewPracticeTimerStateStore: PracticeTimerStateStore {
    private var data: Data?

    func load() -> Data? { data }

    func save(_ data: Data?) throws {
        self.data = data
    }
}

private final class CapturingReviewHTTPTransport: AIHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            self.request = request
        }
        let data = Data(
            """
            {
              "choices": [{
                "message": {
                  "content": "{\\\"facts\\\":[],\\\"patterns\\\":[],\\\"decisions\\\":[],\\\"projectRecommendations\\\":{},\\\"nextSteps\\\":{},\\\"sourceSummary\\\":[],\\\"sourceReferences\\\":{}}"
                }
              }]
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func reviewInput() -> [String: Any]? {
        let body = lock.withLock { request?.httpBody }
        guard let body,
              let outer = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = outer["messages"] as? [[String: Any]],
              let user = messages.first(where: { $0["role"] as? String == "user" }),
              let content = user["content"] as? String,
              let inputData = content.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: inputData) as? [String: Any]
    }
}
