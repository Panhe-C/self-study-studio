import XCTest
@testable import PersonalLearningJournal

final class ProofAttachmentDraftTests: XCTestCase {
    func testCapturedPhotoDraftUsesImageProofDefaults() {
        let data = Data("jpeg".utf8)

        let draft = ProofAttachmentDraft.capturedPhoto(data)

        XCTAssertEqual(draft.data, data)
        XCTAssertNil(draft.fileURL)
        XCTAssertEqual(draft.fileName, "camera-photo.jpg")
        XCTAssertEqual(draft.mimeType, "image/jpeg")
        XCTAssertEqual(draft.proofType, .image)
        XCTAssertEqual(draft.suggestedTitle, "Photo Proof")
    }
}
