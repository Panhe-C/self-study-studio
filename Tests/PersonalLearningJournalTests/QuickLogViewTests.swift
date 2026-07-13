import XCTest
@testable import PersonalLearningJournal

@MainActor
final class QuickLogViewTests: XCTestCase {
    func testSaveRequiresNonEmptySessionNote() {
        XCTAssertFalse(QuickLogView.canSave(note: ""))
        XCTAssertFalse(QuickLogView.canSave(note: "  \n "))
        XCTAssertTrue(QuickLogView.canSave(note: "Reviewed attention notes"))
    }

    func testEmptySessionNoteHasReadableErrorMessage() {
        XCTAssertEqual(
            JournalValidationError.emptySessionNote.localizedDescription,
            "Add one sentence about what you worked on."
        )
    }
}
