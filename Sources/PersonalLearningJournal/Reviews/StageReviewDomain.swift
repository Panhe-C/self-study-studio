import Foundation

public enum StageReviewReadinessReason: String, Codable, CaseIterable, Sendable {
    case phaseEnded
    case sessionsResolved
    case proofAvailable
    case requested
    case unresolvedSessions
    case missingExpectedProof
}

public struct StageReviewReadiness: Codable, Equatable, Identifiable, Sendable {
    public let projectID: UUID
    public let phaseID: UUID
    public let isReady: Bool
    public let reasons: [StageReviewReadinessReason]
    public let facts: [String]
    public let sourceReferences: [String: [String]]
    public let explanation: String

    public var id: UUID { phaseID }

    public init(
        projectID: UUID,
        phaseID: UUID,
        isReady: Bool,
        reasons: [StageReviewReadinessReason],
        facts: [String],
        sourceReferences: [String: [String]],
        explanation: String
    ) {
        self.projectID = projectID
        self.phaseID = phaseID
        self.isReady = isReady
        self.reasons = reasons
        self.facts = facts
        self.sourceReferences = sourceReferences
        self.explanation = explanation
    }
}

/// Deterministic, source-linked readiness and facts for one Project/Phase.
/// This service only prompts; it never creates or publishes a Review.
public struct StageReviewReadinessService: Sendable {
    public init() {}

    public func evaluate(
        projectID: UUID,
        phaseID: UUID,
        snapshot: JournalSnapshot,
        at referenceDate: Date = Date(),
        requested: Bool = false
    ) -> StageReviewReadiness {
        let phase = snapshot.planPhases.first { $0.id == phaseID && $0.deletedAt == nil }
        let projectExists = snapshot.projects.contains { $0.id == projectID && $0.deletedAt == nil }
        guard let phase, projectExists else {
            return StageReviewReadiness(
                projectID: projectID,
                phaseID: phaseID,
                isReady: false,
                reasons: [],
                facts: ["Stage Review is unavailable because its Project or Phase is missing."],
                sourceReferences: [:],
                explanation: "Stage Review unavailable: missing project or phase."
            )
        }

        let sessions = snapshot.plannedSessions
            .filter { $0.phaseId == phaseID && $0.projectId == projectID && $0.deletedAt == nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let unresolved = sessions.filter { $0.status != .completed && $0.status != .skipped }
        let phaseEnded = phase.targetEnd <= referenceDate
        let sessionsResolved = !sessions.isEmpty && unresolved.isEmpty
        let proofs = snapshot.proofs
            .filter { $0.projectId == projectID && $0.deletedAt == nil && $0.qualifies }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        let proofAvailable = !proofs.isEmpty

        var reasons: [StageReviewReadinessReason] = []
        if phaseEnded { reasons.append(.phaseEnded) }
        if sessionsResolved { reasons.append(.sessionsResolved) }
        if proofAvailable { reasons.append(.proofAvailable) }
        if requested { reasons.append(.requested) }
        if !unresolved.isEmpty { reasons.append(.unresolvedSessions) }
        if !proofAvailable { reasons.append(.missingExpectedProof) }

        var facts: [String] = []
        var references: [String: [String]] = [:]
        let phaseFact = "Phase \(phase.title) targets \(phase.targetStart.formatted(date: .abbreviated, time: .omitted))–\(phase.targetEnd.formatted(date: .abbreviated, time: .omitted))."
        facts.append(phaseFact)
        references[phaseFact] = ["PlanPhase:\(phase.id.uuidString)"]
        if sessions.isEmpty {
            let fact = "No Planned Sessions are attached to this phase."
            facts.append(fact)
            references[fact] = ["PlanPhase:\(phase.id.uuidString)"]
        } else {
            let fact = "\(sessions.count - unresolved.count) of \(sessions.count) Planned Sessions are resolved."
            facts.append(fact)
            references[fact] = sessions.map { "PlannedSession:\($0.id.uuidString)" }
        }
        if let proof = proofs.last {
            let fact = "Qualifying-capable Proof is available: \(proof.title)."
            facts.append(fact)
            references[fact] = ["Proof:\(proof.id.uuidString)"]
        } else {
            let fact = "No inspectable Proof is available for this phase yet."
            facts.append(fact)
            references[fact] = ["PlanPhase:\(phase.id.uuidString)"]
        }

        let ready = phaseEnded || sessionsResolved || proofAvailable || requested
        let explanation: String
        if ready {
            explanation = "Stage Review is ready because \(reasons.filter { [.phaseEnded, .sessionsResolved, .proofAvailable, .requested].contains($0) }.map(Self.displayName).joined(separator: ", "))."
        } else {
            explanation = "Stage Review is not ready: unresolved sessions or missing expected proof remain."
        }
        return StageReviewReadiness(
            projectID: projectID,
            phaseID: phaseID,
            isReady: ready,
            reasons: reasons,
            facts: facts,
            sourceReferences: references,
            explanation: explanation
        )
    }

    private static func displayName(_ reason: StageReviewReadinessReason) -> String {
        switch reason {
        case .phaseEnded: "the phase target ended"
        case .sessionsResolved: "all planned sessions resolved"
        case .proofAvailable: "proof is available"
        case .requested: "the learner requested a review"
        case .unresolvedSessions, .missingExpectedProof: "follow-up is needed"
        }
    }
}
