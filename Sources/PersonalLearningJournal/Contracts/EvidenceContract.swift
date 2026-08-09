import Foundation

public enum EvidenceContractTrigger: Codable, Equatable, Sendable {
    case interval(days: Int)
    case milestone(String)
}

public struct EvidenceContract: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var trigger: EvidenceContractTrigger
    public var expectedArtifact: ProofType
    public var acceptanceCriteria: String
    public var startsAt: Date
    public var endedAt: Date?
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        trigger: EvidenceContractTrigger,
        expectedArtifact: ProofType,
        acceptanceCriteria: String,
        startsAt: Date,
        endedAt: Date? = nil,
        revision: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) throws {
        let criteria = acceptanceCriteria.trimmedForJournal
        guard !criteria.isEmpty else {
            throw JournalValidationError.missingAcceptanceCriteria
        }
        switch trigger {
        case let .interval(days):
            guard days > 0 else { throw JournalValidationError.invalidEvidenceInterval }
        case let .milestone(value):
            guard !value.trimmedForJournal.isEmpty else {
                throw JournalValidationError.missingAcceptanceCriteria
            }
        }

        self.id = id
        self.projectId = projectId
        self.trigger = trigger
        self.expectedArtifact = expectedArtifact
        self.acceptanceCriteria = criteria
        self.startsAt = startsAt
        self.endedAt = endedAt
        self.revision = max(1, revision)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public static func weekly(
        projectId: UUID,
        expectedArtifact: ProofType,
        acceptanceCriteria: String,
        startsAt: Date
    ) throws -> EvidenceContract {
        try EvidenceContract(
            projectId: projectId,
            trigger: .interval(days: 7),
            expectedArtifact: expectedArtifact,
            acceptanceCriteria: acceptanceCriteria,
            startsAt: startsAt,
            createdAt: startsAt,
            updatedAt: startsAt
        )
    }

    public var isActive: Bool {
        endedAt == nil && deletedAt == nil
    }
}

public struct EvidenceAcceptance: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var contractId: UUID
    public var proofId: UUID
    /// Optional Stage Review linkage. Legacy contract acceptances leave these
    /// nil and remain valid for the recurring Evidence Contract flow.
    public var phaseId: UUID?
    public var reviewId: UUID?
    public var proofRevisionId: UUID?
    public var acceptedCriteria: [String]
    public var acceptedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        contractId: UUID,
        proofId: UUID,
        phaseId: UUID? = nil,
        reviewId: UUID? = nil,
        proofRevisionId: UUID? = nil,
        acceptedCriteria: [String],
        acceptedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.contractId = contractId
        self.proofId = proofId
        self.phaseId = phaseId
        self.reviewId = reviewId
        self.proofRevisionId = proofRevisionId
        self.acceptedCriteria = acceptedCriteria.map { $0.trimmedForJournal }.filter { !$0.isEmpty }
        self.acceptedAt = acceptedAt
        self.deletedAt = deletedAt
    }

    public var isQualifyingProof: Bool {
        phaseId != nil && reviewId != nil && proofRevisionId != nil && deletedAt == nil
    }
}

/// A source-compatible name for the explicit phase-scoped acceptance carried
/// by `EvidenceAcceptance`; persisted records remain `EvidenceAcceptance`.
public typealias QualifyingProof = EvidenceAcceptance
