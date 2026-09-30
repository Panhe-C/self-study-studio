import Foundation

/// Immutable snapshot of a confirmed learning record taken before a later
/// amendment (spec 4.6). Revisions are created once and never edited: amend
/// flows append a new snapshot and then update the session. The UI shows the
/// latest session values by default and offers the revision history on demand.
public struct LearningRecordRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var revision: Int
    public var previousNote: String
    public var previousAssessment: LearningRecordAssessment?
    public var revisedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        revision: Int,
        previousNote: String,
        previousAssessment: LearningRecordAssessment? = nil,
        revisedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.revision = max(1, revision)
        self.previousNote = previousNote
        self.previousAssessment = previousAssessment
        self.revisedAt = revisedAt
        self.deletedAt = deletedAt
    }

    public init(
        id: UUID = UUID(),
        session: LearningSession,
        revision: Int,
        revisedAt: Date = Date()
    ) {
        self.init(
            id: id,
            sessionID: session.id,
            revision: revision,
            previousNote: session.note,
            previousAssessment: session.assessment,
            revisedAt: revisedAt
        )
    }
}
