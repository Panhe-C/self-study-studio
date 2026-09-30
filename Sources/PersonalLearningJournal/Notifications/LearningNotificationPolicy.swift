import Foundation

public enum LearningNotificationCategory: String, CaseIterable, Codable, Sendable {
    case confirmedStudyTime
    case contractBoundary
    case pendingReview
    case pendingCompletionCheck
    case pendingRecordConfirmation
}

public struct LearningNotificationPayload: Equatable, Sendable {
    public var category: LearningNotificationCategory
    public var title: String
    public var body: String

    public init(category: LearningNotificationCategory, title: String, body: String) {
        self.category = category
        self.title = title
        self.body = body
    }
}

public struct LearningNotificationPolicy: Sendable {
    public init() {}

    public func payload(for category: LearningNotificationCategory) -> LearningNotificationPayload {
        let body = switch category {
        case .confirmedStudyTime:
            "A confirmed study time is approaching."
        case .contractBoundary:
            "A learning commitment needs attention."
        case .pendingReview:
            "A learning review is ready for your decision."
        case .pendingCompletionCheck:
            "A study session is waiting for its completion check."
        case .pendingRecordConfirmation:
            "Your learning record draft is ready to confirm."
        }
        return LearningNotificationPayload(
            category: category,
            title: "Self Study Studio",
            body: body
        )
    }
}
