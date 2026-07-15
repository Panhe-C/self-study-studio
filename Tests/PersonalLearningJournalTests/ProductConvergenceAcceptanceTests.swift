import XCTest
@testable import PersonalLearningJournal

final class ProductConvergenceAcceptanceTests: XCTestCase {
    func testEvidenceFirstLoopSurvivesTrashAndEncryptedArchiveRestore() throws {
        let timestamp = Date(timeIntervalSince1970: 2_000_000)
        let repository = InMemoryJournalRepository(now: { timestamp })
        let journal = JournalService(repository: repository, now: { timestamp })
        let idea = try journal.createIdea(name: "Acceptance", area: "Learning")
        let contract = try EvidenceContract.weekly(
            projectId: idea.id,
            expectedArtifact: .text,
            acceptanceCriteria: "Explains the result",
            startsAt: timestamp
        )
        _ = try journal.activateProject(
            projectId: idea.id,
            goal: "Complete one evidence-first loop",
            nextStep: "Write the result",
            contract: contract
        )
        let session = try journal.quickLog(
            projectId: idea.id,
            actionType: .output,
            durationMinutes: 25,
            note: "Created an explanation",
            nextStep: "Review the evidence"
        )
        let proof = try journal.addProof(
            projectId: idea.id,
            sessionId: session.id,
            type: .text,
            title: "Result explanation",
            statement: "Shows the result is understood",
            artifactBody: "A concise explanation with the observed result."
        )
        _ = try journal.acceptProof(
            proofId: proof.id,
            contractId: contract.id,
            acceptedCriteria: ["Explains the result"]
        )
        let review = Review(
            periodStart: timestamp.addingTimeInterval(-86_400),
            periodEnd: timestamp,
            facts: ["One qualifying Proof"],
            patterns: [],
            decisions: [],
            projectRecommendations: [:],
            nextSteps: [:],
            aiSourceSummary: []
        )
        try journal.recordReview(review)
        _ = try journal.completeReview(
            reviewId: review.id,
            decision: ReviewDecision(
                reviewId: review.id,
                projectId: idea.id,
                kind: .continueUnchanged,
                decidedAt: timestamp
            )
        )

        try journal.moveToTrash(projectId: idea.id)
        XCTAssertEqual(journal.project(id: idea.id)?.status, .trash)
        try journal.restoreFromTrash(projectId: idea.id)
        XCTAssertEqual(journal.project(id: idea.id)?.status, .active)

        let snapshot = journal.snapshot()
        let archive = JournalArchiveService(now: { timestamp }, derivationRounds: 20)
        let envelope = try archive.export(
            snapshot: snapshot,
            attachments: [:],
            password: "acceptance-password"
        )
        let preview = try archive.preview(envelope, password: "acceptance-password")
        let restored = try archive.restore(preview).snapshot
        let health = ProductHealthService().report(snapshot: restored, now: timestamp)

        XCTAssertEqual(restored.projects.map(\.id), [idea.id])
        XCTAssertEqual(restored.sessions.map(\.id), [session.id])
        XCTAssertEqual(restored.proofs.map(\.id), [proof.id])
        XCTAssertEqual(health.silentMisses, 0)
        XCTAssertEqual(health.incompleteReviews, 0)
        XCTAssertEqual(health.canonicalStepProjects, 1)
    }
}
