import Foundation

public enum ReviewDecisionKind: String, Codable, CaseIterable, Sendable {
    case continueUnchanged
    case changeNextStep
    case reviseContract
    case changeFrequency
    case pause
    case abandon
    /// Stage Review decisions keep phase progression explicit and separate
    /// from the legacy project-completion decision.
    case advancePhase
    case extendPhase
    case revisePhase

    // Legacy persisted review decisions remain decodable. New UI writes `.abandon`.
    case archive
    case complete

    public static var allCases: [ReviewDecisionKind] {
        [.continueUnchanged, .changeNextStep, .reviseContract, .changeFrequency, .advancePhase, .extendPhase, .revisePhase, .pause, .abandon, .complete]
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
    public var phaseId: UUID?
    /// The accepted phase-proof linkage created by a Stage Review publish.
    public var qualifyingProofAcceptanceId: UUID?
    /// The structural revision draft created by a revise/extend decision.
    public var planRevisionDraftId: UUID?
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
        phaseId: UUID? = nil,
        qualifyingProofAcceptanceId: UUID? = nil,
        planRevisionDraftId: UUID? = nil,
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
        self.phaseId = phaseId
        self.qualifyingProofAcceptanceId = qualifyingProofAcceptanceId
        self.planRevisionDraftId = planRevisionDraftId
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
        case .advancePhase:
            phaseId != nil && qualifyingProofAcceptanceId != nil
        case .extendPhase, .revisePhase:
            phaseId != nil
        case .continueUnchanged, .pause, .abandon, .archive:
            true
        }
    }
}
