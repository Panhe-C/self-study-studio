import XCTest
@testable import PersonalLearningJournal

final class ProofPreviewTests: XCTestCase {
    func testLocalAudioProofProducesAudioPreview() throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("practice-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
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

    func testUnreadableAttachmentAndInvalidLinkAreUnavailable() throws {
        let attachment = try Proof(
            projectId: UUID(),
            type: .file,
            title: "Missing file",
            statement: "Shows the result",
            localPath: "/tmp/does-not-exist-\(UUID().uuidString)"
        )
        let invalidLink = try Proof(
            projectId: UUID(),
            type: .link,
            title: "Local link",
            statement: "Shows the result",
            url: URL(string: "file:///tmp/result")
        )

        XCTAssertEqual(ProofPreviewDescriptor(proof: attachment).kind, .unavailable)
        XCTAssertEqual(ProofPreviewDescriptor(proof: invalidLink).kind, .unavailable)
    }
}
