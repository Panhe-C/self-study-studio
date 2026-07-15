import XCTest
@testable import PersonalLearningJournal

final class ProductHealthServiceTests: XCTestCase {
    func testDeliberatePauseResolvesMissInsteadOfCountingAsFailure() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let contract = try EvidenceContract.weekly(
            projectId: UUID(),
            expectedArtifact: .audio,
            acceptanceCriteria: "Clean recording",
            startsAt: now.addingTimeInterval(-8 * 86_400)
        )
        let project = Project(
            id: contract.projectId,
            name: "Guitar",
            area: "Music",
            goal: "Play",
            status: .paused,
            currentNextStep: "Practice",
            activeEvidenceContractId: contract.id
        )
        let decision = ReviewDecision(
            reviewId: UUID(),
            projectId: project.id,
            kind: .pause,
            decidedAt: now.addingTimeInterval(-86_400)
        )

        let report = ProductHealthService().report(
            snapshot: JournalSnapshot(
                projects: [project],
                evidenceContracts: [contract],
                reviewDecisions: [decision]
            ),
            now: now
        )

        XCTAssertEqual(report.silentMisses, 0)
        XCTAssertEqual(report.resolvedContractPeriods, 1)
    }

    func testReportSeparatesCoverageAcceptedPeriodsIncompleteReviewsAndProofSequences() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let contract = try EvidenceContract.weekly(
            projectId: UUID(),
            expectedArtifact: .text,
            acceptanceCriteria: "Working explanation",
            startsAt: now.addingTimeInterval(-7 * 86_400)
        )
        let project = Project(
            id: contract.projectId,
            name: "CS336",
            area: "AI",
            goal: "Learn",
            currentNextStep: "Write",
            activeEvidenceContractId: contract.id
        )
        let proof = try Proof.text(
            projectId: project.id,
            title: "Notes",
            artifactBody: "# Notes",
            statement: "I can explain this",
            createdAt: now
        )
        let acceptance = EvidenceAcceptance(
            contractId: contract.id,
            proofId: proof.id,
            acceptedCriteria: ["Working explanation"],
            acceptedAt: now
        )
        let revisions = [1, 2].map {
            ProofRevision(
                proofId: proof.id,
                revision: $0,
                title: proof.title,
                statement: proof.statement,
                artifactChecksum: "revision-\($0)",
                createdAt: now
            )
        }
        let review = Review(
            periodStart: now.addingTimeInterval(-7 * 86_400),
            periodEnd: now,
            facts: [], patterns: [], decisions: [], projectRecommendations: [:],
            nextSteps: [:], aiSourceSummary: [], createdAt: now, updatedAt: now
        )

        let report = ProductHealthService().report(
            snapshot: JournalSnapshot(
                projects: [project],
                proofs: [proof],
                reviews: [review],
                evidenceContracts: [contract],
                evidenceAcceptances: [acceptance],
                proofRevisions: revisions
            ),
            now: now
        )

        XCTAssertEqual(report.canonicalStepProjects, 1)
        XCTAssertEqual(report.eligibleProjects, 1)
        XCTAssertEqual(report.acceptedContractPeriods, 1)
        XCTAssertEqual(report.silentMisses, 0)
        XCTAssertEqual(report.incompleteReviews, 1)
        XCTAssertEqual(report.projectsWithProofSequences, 1)
        XCTAssertEqual(report.projectFacts.first?.projectId, project.id)
    }
}
