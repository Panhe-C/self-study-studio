import XCTest
@testable import PersonalLearningJournal

final class ProofSearchIndexTests: XCTestCase {
    func testDefaultLibraryExcludesNeedsEvidence() throws {
        let projectID = UUID()
        let qualifying = try Proof.text(
            projectId: projectID,
            title: "Derivation",
            artifactBody: "The answer follows from the invariant.",
            statement: "Explains the result"
        )
        let needsEvidence = try Proof(
            projectId: projectID,
            type: .image,
            title: "Legacy screenshot",
            statement: "Shows the result"
        )
        let snapshot = JournalSnapshot(
            projects: [Project(name: "Algorithms", area: "CS", goal: "Learn", status: .idea, currentNextStep: "")],
            proofs: [qualifying, needsEvidence]
        )

        let results = ProofSearchIndex(snapshot: snapshot).search("")

        XCTAssertEqual(results.map(\.proof.id), [qualifying.id])
        XCTAssertTrue(results.allSatisfy(\.proof.qualifies))
    }

    func testSearchIndexesClaimProjectTextBodyAndLocalDerivedText() throws {
        let project = Project(name: "Signal Processing", area: "Audio", goal: "Learn", status: .idea, currentNextStep: "")
        let proof = try Proof.text(
            projectId: project.id,
            title: "Fourier notes",
            artifactBody: "Windowing reduces spectral leakage.",
            statement: "I can explain the tradeoff"
        )
        var index = ProofSearchIndex(
            snapshot: JournalSnapshot(projects: [project], proofs: [proof]),
            locallyDerivedText: [proof.id: "transcribed hann experiment"]
        )

        XCTAssertEqual(index.search("signal").map(\.proof.id), [proof.id])
        XCTAssertEqual(index.search("spectral leakage").map(\.proof.id), [proof.id])
        XCTAssertEqual(index.search("HANN").map(\.proof.id), [proof.id])

        index.rebuild(snapshot: JournalSnapshot(projects: [project], proofs: [proof]))
        XCTAssertTrue(index.search("transcribed").isEmpty)
    }
}
