import XCTest
@testable import PersonalLearningJournal

final class TodayRecommendationServiceTests: XCTestCase {
    func testRecommendationOrderIsPinnedThenContractThenScheduleAndCapsAtThree() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pinned = activeProject(name: "Pinned", createdAt: now.addingTimeInterval(-400))
        let contractProject = activeProject(name: "Contract", createdAt: now.addingTimeInterval(-300))
        let scheduledProject = activeProject(name: "Scheduled", createdAt: now.addingTimeInterval(-200))
        let staleProject = activeProject(name: "Stale", createdAt: now.addingTimeInterval(-100))
        let contract = try EvidenceContract.weekly(
            projectId: contractProject.id,
            expectedArtifact: .text,
            acceptanceCriteria: "Explain it",
            startsAt: now.addingTimeInterval(-7 * 86_400)
        )
        let scheduled = try PlannedSession(
            planId: UUID(),
            phaseId: UUID(),
            projectId: scheduledProject.id,
            title: "Confirmed work",
            actionType: .output,
            durationMinutes: 30,
            deadline: now,
            status: .scheduled,
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-100)
        )
        var contractLinkedProject = contractProject
        contractLinkedProject.activeEvidenceContractId = contract.id
        let snapshot = JournalSnapshot(
            projects: [staleProject, scheduledProject, contractLinkedProject, pinned],
            evidenceContracts: [contract],
            plannedSessions: [scheduled]
        )
        let service = TodayRecommendationService(pinnedProjectIDs: [pinned.id])

        let recommendations = service.recommendations(snapshot: snapshot, now: now, limit: 10)

        XCTAssertEqual(recommendations.map(\.reason), [.userPinned, .contractBoundary, .confirmedSchedule])
        XCTAssertEqual(recommendations.map(\.projectId), [pinned.id, contractProject.id, scheduledProject.id])
        XCTAssertEqual(recommendations.map(\.isPrimary), [true, false, false])
    }

    func testStableTieBreakUsesDueDateThenActivityCreationAndUUID() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let older = activeProject(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Older",
            createdAt: now.addingTimeInterval(-200)
        )
        let newer = activeProject(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Newer",
            createdAt: now.addingTimeInterval(-100)
        )

        let sharedActivity = try! LearningSession(
            projectId: older.id,
            source: .quickLog,
            actionType: .reading,
            startedAt: now.addingTimeInterval(-60),
            endedAt: now,
            durationMinutes: 1,
            note: "Same activity",
            nextStepBefore: "Next",
            nextStepAfter: "Next"
        )
        var newerActivity = sharedActivity
        newerActivity.id = UUID()
        newerActivity.projectId = newer.id
        let result = TodayRecommendationService().recommendations(
            snapshot: JournalSnapshot(
                projects: [newer, older],
                sessions: [newerActivity, sharedActivity]
            ),
            now: now
        )

        XCTAssertEqual(result.map(\.projectId), [older.id, newer.id])
    }

    private func activeProject(
        id: UUID = UUID(),
        name: String,
        createdAt: Date
    ) -> Project {
        Project(
            id: id,
            name: name,
            area: "Test",
            goal: "Goal",
            currentNextStep: "Next",
            createdAt: createdAt,
            updatedAt: createdAt,
            activeEvidenceContractId: UUID()
        )
    }
}
