import XCTest
@testable import PersonalLearningJournal

final class EvidenceFirstDomainTests: XCTestCase {
    func testIdeaExposesActivationIssuesWithoutConsumingAttention() {
        let project = Project(
            name: "Shaders",
            area: "Graphics",
            goal: "",
            status: .idea,
            currentNextStep: ""
        )

        XCTAssertEqual(
            project.activationIssues(contract: nil),
            [.missingGoal, .missingNextStep, .missingContract]
        )
        XCTAssertFalse(project.countsTowardAttentionBudget)
        XCTAssertFalse(project.canContinue)
    }

    func testActiveReadyProjectCountsTowardAttentionBudget() throws {
        let projectID = UUID()
        let contract = try EvidenceContract.weekly(
            projectId: projectID,
            expectedArtifact: .text,
            acceptanceCriteria: "Explains the technique with a runnable example",
            startsAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let project = Project(
            id: projectID,
            name: "Shaders",
            area: "Graphics",
            goal: "Build one shader",
            status: .active,
            currentNextStep: "Implement the vertex stage",
            activeEvidenceContractId: contract.id
        )

        XCTAssertEqual(project.activationIssues(contract: contract), [])
        XCTAssertTrue(project.countsTowardAttentionBudget)
        XCTAssertTrue(project.canContinue)
    }

    func testLowFrequencyProjectDoesNotCountTowardActiveBudget() throws {
        let projectID = UUID()
        let contract = try EvidenceContract.weekly(
            projectId: projectID,
            expectedArtifact: .audio,
            acceptanceCriteria: "One complete performance recording",
            startsAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let project = Project(
            id: projectID,
            name: "Guitar",
            area: "Music",
            goal: "Play one song",
            status: .lowFrequency,
            currentNextStep: "Practice the chorus",
            activeEvidenceContractId: contract.id
        )

        XCTAssertFalse(project.countsTowardAttentionBudget)
        XCTAssertEqual(project.activationIssues(contract: contract), [])
    }

    func testStatementOnlyLegacyProofNeedsEvidence() throws {
        let proof = try Proof(
            projectId: UUID(),
            type: .image,
            title: "Old screenshot",
            statement: "Shows the result"
        )

        XCTAssertEqual(proof.integrity, .needsEvidence)
        XCTAssertNil(proof.artifact)
        XCTAssertFalse(proof.qualifies)
    }

    func testTextProofSeparatesArtifactFromClaim() throws {
        let proof = try Proof.text(
            projectId: UUID(),
            title: "Derivation",
            artifactBody: "# Result\n\nThe answer is 42.",
            statement: "I can derive the result in my own words"
        )

        XCTAssertEqual(proof.type, .text)
        XCTAssertEqual(proof.artifactBody, "# Result\n\nThe answer is 42.")
        XCTAssertEqual(proof.integrity, .qualifying)
        XCTAssertTrue(proof.qualifies)
    }

    func testLinkProofRequiresHTTPOrHTTPSURLToQualify() throws {
        let invalid = try Proof(
            projectId: UUID(),
            type: .link,
            title: "Local path",
            statement: "Shows the output",
            url: URL(string: "file:///tmp/output")
        )
        let valid = try Proof(
            projectId: UUID(),
            type: .link,
            title: "Commit",
            statement: "Shows the implemented feature",
            url: URL(string: "https://example.com/commit/1")
        )

        XCTAssertFalse(invalid.qualifies)
        XCTAssertTrue(valid.qualifies)
    }

    func testReferencedProofRevisionPreservesHistoricalSnapshot() throws {
        let proof = try Proof.text(
            projectId: UUID(),
            title: "Explanation",
            artifactBody: "Original body",
            statement: "Original claim"
        )
        let revision = ProofRevision(
            proof: proof,
            revision: 1,
            artifactChecksum: "sha256:abc",
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        XCTAssertEqual(revision.proofId, proof.id)
        XCTAssertEqual(revision.title, "Explanation")
        XCTAssertEqual(revision.statement, "Original claim")
        XCTAssertEqual(revision.artifactChecksum, "sha256:abc")
    }

    func testReviewDecisionCompletionRequiresCapstoneProof() {
        let withoutProof = ReviewDecision(
            reviewId: UUID(),
            projectId: UUID(),
            kind: .complete,
            decidedAt: Date()
        )
        let withProof = ReviewDecision(
            reviewId: UUID(),
            projectId: UUID(),
            kind: .complete,
            capstoneProofId: UUID(),
            decidedAt: Date()
        )

        XCTAssertFalse(withoutProof.isValid)
        XCTAssertTrue(withProof.isValid)
    }

    func testLegacyActiveProjectDecodesAsNeedsSetup() throws {
        let data = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"CS336","area":"AI","goal":"Finish","status":"active","currentNextStep":"Lecture 1","lastActionType":"course","defaultDurationMinutes":30,"createdAt":"2001-01-01T00:00:00Z","updatedAt":"2001-01-01T00:00:00Z"}"#.utf8
        )

        let project = try JSONDecoder.journal.decode(Project.self, from: data)

        XCTAssertEqual(project.commitmentState, .needsSetup)
        XCTAssertFalse(project.countsTowardAttentionBudget)
    }
}
