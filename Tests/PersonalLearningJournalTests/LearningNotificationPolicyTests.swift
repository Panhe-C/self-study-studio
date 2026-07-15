import XCTest
@testable import PersonalLearningJournal

final class LearningNotificationPolicyTests: XCTestCase {
    func testOnlySupportedCategoriesProduceGenericLockScreenCopy() {
        let policy = LearningNotificationPolicy()

        XCTAssertEqual(Set(LearningNotificationCategory.allCases), [
            .confirmedStudyTime,
            .contractBoundary,
            .pendingReview
        ])
        for category in LearningNotificationCategory.allCases {
            let payload = policy.payload(for: category)
            XCTAssertEqual(payload.title, "Self Study Studio")
            XCTAssertFalse(payload.body.contains("CS336"))
            XCTAssertFalse(payload.body.contains("tokenizer"))
            XCTAssertFalse(payload.body.isEmpty)
        }
    }
}
