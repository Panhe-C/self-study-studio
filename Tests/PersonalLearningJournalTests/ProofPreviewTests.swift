import XCTest
@testable import PersonalLearningJournal

final class ProofPreviewTests: XCTestCase {
    func testLocalAudioProofProducesAudioPreview() throws {
        let localURL = URL(fileURLWithPath: "/tmp/practice.m4a")
        let proof = try Proof(
            projectId: UUID(),
            type: .audio,
            title: "练习录音",
            statement: "能完整弹完第一段",
            localPath: localURL.path,
            mimeType: "audio/m4a"
        )

        XCTAssertEqual(
            ProofPreviewDescriptor(proof: proof).kind,
            .audio(localURL)
        )
    }

    func testLinkProofProducesExternalLinkPreview() throws {
        let link = try XCTUnwrap(URL(string: "https://github.com/example/notebook"))
        let proof = try Proof(
            projectId: UUID(),
            type: .link,
            title: "Notebook",
            statement: "复现了 bigram baseline",
            url: link
        )

        XCTAssertEqual(
            ProofPreviewDescriptor(proof: proof).kind,
            .link(link)
        )
    }

    func testMissingLocalAttachmentIsUnavailable() throws {
        let proof = try Proof(
            projectId: UUID(),
            type: .image,
            title: "截图",
            statement: "能控制白平衡"
        )

        XCTAssertEqual(ProofPreviewDescriptor(proof: proof).kind, .unavailable)
    }
}
