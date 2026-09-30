import XCTest
@testable import PersonalLearningJournal

final class LearningNotificationPolicyTests: XCTestCase {
    func testOnlySupportedCategoriesProduceGenericLockScreenCopy() {
        let policy = LearningNotificationPolicy()

        XCTAssertEqual(Set(LearningNotificationCategory.allCases), [
            .confirmedStudyTime,
            .contractBoundary,
            .pendingReview,
            .pendingCompletionCheck,
            .pendingRecordConfirmation
        ])
        for category in LearningNotificationCategory.allCases {
            let payload = policy.payload(for: category)
            XCTAssertEqual(payload.title, "Self Study Studio")
            XCTAssertFalse(payload.body.contains("CS336"))
            XCTAssertFalse(payload.body.contains("tokenizer"))
            XCTAssertFalse(payload.body.isEmpty)
        }
    }

    /// Spec 13: pending-capture reminders nudge the user back to the exact
    /// pending step without streaks, shame, or unconfirmed completion claims.
    func testPendingCaptureCopyIsNeutralAndActionable() {
        let policy = LearningNotificationPolicy()

        let check = policy.payload(for: .pendingCompletionCheck)
        XCTAssertEqual(check.body, "A study session is waiting for its completion check.")

        let record = policy.payload(for: .pendingRecordConfirmation)
        XCTAssertEqual(record.body, "Your learning record draft is ready to confirm.")

        let forbidden = ["streak", "missed", "failed", "behind", "completed", "finished"]
        for payload in [check, record] {
            let lowercased = payload.body.lowercased()
            for word in forbidden {
                XCTAssertFalse(
                    lowercased.contains(word),
                    "'\(payload.body)' must not contain '\(word)'"
                )
            }
        }
    }
}
