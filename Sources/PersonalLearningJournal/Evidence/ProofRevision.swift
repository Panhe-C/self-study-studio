import Foundation

public struct ProofRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var proofId: UUID
    public var revision: Int
    public var title: String
    public var statement: String
    public var artifactChecksum: String
    public var createdAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        proofId: UUID,
        revision: Int,
        title: String,
        statement: String,
        artifactChecksum: String,
        createdAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.proofId = proofId
        self.revision = max(1, revision)
        self.title = title
        self.statement = statement
        self.artifactChecksum = artifactChecksum
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }

    public init(
        id: UUID = UUID(),
        proof: Proof,
        revision: Int,
        artifactChecksum: String,
        createdAt: Date = Date()
    ) {
        self.init(
            id: id,
            proofId: proof.id,
            revision: revision,
            title: proof.title,
            statement: proof.statement,
            artifactChecksum: artifactChecksum,
            createdAt: createdAt
        )
    }
}
