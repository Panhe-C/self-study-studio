import Foundation

public enum ReviewDecisionKind: String, Codable, CaseIterable, Sendable {
    case continueUnchanged
    case changeNextStep
    case reviseContract
    case changeFrequency
    case pause
    case abandon

    // Legacy persisted review decisions remain decodable. New UI writes `.abandon`.
    case archive
    case complete

    public static var allCases: [ReviewDecisionKind] {
        [.continueUnchanged, .changeNextStep, .reviseContract, .changeFrequency, .pause, .abandon, .complete]
    }
}

public struct ReviewDecision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var reviewId: UUID
    public var projectId: UUID
    public var kind: ReviewDecisionKind
    public var nextStep: String?
    public var contractId: UUID?
    public var capstoneProofId: UUID?
    public var decidedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        reviewId: UUID,
        projectId: UUID,
        kind: ReviewDecisionKind,
        nextStep: String? = nil,
        contractId: UUID? = nil,
        capstoneProofId: UUID? = nil,
        decidedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.reviewId = reviewId
        self.projectId = projectId
        self.kind = kind
        self.nextStep = nextStep?.trimmedForJournal
        self.contractId = contractId
        self.capstoneProofId = capstoneProofId
        self.decidedAt = decidedAt
        self.deletedAt = deletedAt
    }

    public var isValid: Bool {
        switch kind {
        case .changeNextStep:
            nextStep?.isEmpty == false
        case .reviseContract, .changeFrequency:
            contractId != nil
        case .complete:
            capstoneProofId != nil
        case .continueUnchanged, .pause, .abandon, .archive:
            true
        }
    }
}
