import XCTest
@testable import PersonalLearningJournal

@MainActor
final class StudyCalendarEndToEndTests: XCTestCase {
    func testCoursePlanScheduleCalendarSessionProofAndReview() async throws {
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project]),
            now: { self.timestamp }
        )
        let planningService = CoursePlanningService(repository: repository, now: { self.timestamp })
        let journalService = JournalService(repository: repository, now: { self.timestamp })
        let draftPlan = try planningService.saveDraft(input: input, draft: courseDraft)
        _ = try planningService.activate(draftPlanID: draftPlan.id)
        let planned = try XCTUnwrap(try repository.snapshot().plannedSessions.first)
        let preferences = try SchedulingPreferences(
            preferredSessionMinutes: 45,
            maximumDailyMinutes: 180,
            minimumGapMinutes: 15
        )
        let availability = try (1...7).map { weekday in
            try AvailabilityRule(
                weekday: weekday,
                startMinute: 8 * 60,
                endMinute: 22 * 60,
                timeZoneIdentifier: "Asia/Shanghai",
                minimumSessionMinutes: 15
            )
        }
        let range = DateInterval(start: timestamp, duration: 7 * 86_400)
        let schedule = try StudySchedulingEngine().makeDraft(
            SchedulingRequest(
                sessions: [planned],
                availability: availability,
                preferences: preferences,
                busyIntervals: [],
                pinnedPlacements: [],
                range: range,
                timeZoneIdentifier: "Asia/Shanghai",
                now: timestamp
            )
        )
        try repository.saveTargetCalendarIdentifier("study-calendar")
        let calendarClient = EndToEndCalendarClient()
        let calendarSync = CalendarSyncService(
            repository: repository,
            calendarClient: calendarClient,
            now: { self.timestamp }
        )

        let changes = try await calendarSync.previewChanges(for: schedule)
        let applied = await calendarSync.applyConfirmed(changes)

        XCTAssertTrue(applied.failed.isEmpty)
        XCTAssertNotNil(try repository.calendarBinding(for: planned.id))

        let session = try journalService.quickLog(
            projectId: project.id,
            actionType: planned.actionType,
            durationMinutes: planned.durationMinutes,
            note: "Completed planned work",
            plannedSessionId: planned.id,
            endedAt: timestamp.addingTimeInterval(3_600)
        )
        let proof = try journalService.addProof(
            projectId: project.id,
            sessionId: session.id,
            type: .link,
            title: "Notebook",
            statement: "The planned output now runs",
            url: URL(string: "https://example.com/notebook")
        )
        let review = try await ReviewService(
            journalService: journalService,
            provider: RuleBasedReviewProvider(),
            now: { self.timestamp.addingTimeInterval(7_200) }
        ).createWeeklyReview(
            periodStart: timestamp.addingTimeInterval(-86_400),
            periodEnd: timestamp.addingTimeInterval(86_400)
        )
        let finalSnapshot = try repository.snapshot()

        XCTAssertEqual(finalSnapshot.plannedSessions.first?.status, .completed)
        XCTAssertEqual(finalSnapshot.plannedSessions.first?.completedSessionId, session.id)
        XCTAssertEqual(finalSnapshot.proofs.first?.id, proof.id)
        XCTAssertTrue(review.aiSourceSummary.contains { $0.contains("plan") })
        XCTAssertTrue(finalSnapshot.trailEvents.contains { $0.type == .calendarSynced })
    }

    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let project = Project(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000300")!,
        name: "CS336",
        area: "AI",
        goal: "Build a tokenizer",
        currentNextStep: "Read lecture 1",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    private var input: CoursePlanningInput {
        CoursePlanningInput(
            projectId: project.id,
            courseTitle: "CS336",
            courseOutline: "Lecture 1: tokenization",
            goal: project.goal,
            expectedOutcome: "Tokenizer notebook",
            startsOn: timestamp,
            deadline: timestamp.addingTimeInterval(7 * 86_400),
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45
        )
    }

    private var courseDraft: CoursePlanDraft {
        CoursePlanDraft(
            title: "CS336 plan",
            summary: "Tokenizer foundation",
            phases: [
                CoursePlanDraftPhase(
                    id: "foundations",
                    title: "Foundations",
                    objective: "Understand tokenization",
                    expectedProof: "Tokenizer notebook",
                    ordinal: 0,
                    targetStart: timestamp,
                    targetEnd: timestamp.addingTimeInterval(7 * 86_400)
                )
            ],
            sessions: [
                CoursePlanDraftSession(
                    id: "tokenizer",
                    phaseID: "foundations",
                    title: "Implement tokenizer",
                    actionType: .course,
                    expectedProof: "Tokenizer notebook",
                    durationMinutes: 45,
                    deadline: timestamp.addingTimeInterval(86_400)
                )
            ]
        )
    }
}

private actor EndToEndCalendarClient: CalendarClient {
    private var events: [String: CalendarEventSnapshot] = [:]

    func authorizationState() async -> CalendarAuthorizationState { .fullAccess }
    func requestFullAccess() async throws -> CalendarAuthorizationState { .fullAccess }
    func writableCalendars() async throws -> [CalendarDescriptor] { [] }
    func busyIntervals(in range: DateInterval) async throws -> [BusyInterval] { [] }
    func event(identifier: String) async throws -> CalendarEventSnapshot? { events[identifier] }

    func save(_ event: CalendarEventDraft) async throws -> CalendarEventSnapshot {
        let identifier = event.identifier ?? "event-\(events.count + 1)"
        let saved = CalendarEventSnapshot(
            identifier: identifier,
            calendarIdentifier: event.calendarIdentifier,
            title: event.title,
            start: event.start,
            end: event.end
        )
        events[identifier] = saved
        return saved
    }

    func delete(identifier: String) async throws {
        events.removeValue(forKey: identifier)
    }
}
