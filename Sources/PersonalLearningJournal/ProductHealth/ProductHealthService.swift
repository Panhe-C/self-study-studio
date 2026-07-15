import Foundation

public struct ProjectHealthFact: Equatable, Identifiable, Sendable {
    public var id: UUID { projectId }
    public var projectId: UUID
    public var hasCanonicalStep: Bool
    public var acceptedContractPeriods: Int
    public var resolvedContractPeriods: Int
    public var silentMisses: Int
    public var hasProofSequence: Bool

    public init(
        projectId: UUID,
        hasCanonicalStep: Bool,
        acceptedContractPeriods: Int,
        resolvedContractPeriods: Int,
        silentMisses: Int,
        hasProofSequence: Bool
    ) {
        self.projectId = projectId
        self.hasCanonicalStep = hasCanonicalStep
        self.acceptedContractPeriods = acceptedContractPeriods
        self.resolvedContractPeriods = resolvedContractPeriods
        self.silentMisses = silentMisses
        self.hasProofSequence = hasProofSequence
    }
}

public struct ProductHealthReport: Equatable, Sendable {
    public var eligibleProjects: Int
    public var canonicalStepProjects: Int
    public var acceptedContractPeriods: Int
    public var resolvedContractPeriods: Int
    public var silentMisses: Int
    public var incompleteReviews: Int
    public var projectsWithProofSequences: Int
    public var projectFacts: [ProjectHealthFact]

    public init(
        eligibleProjects: Int,
        canonicalStepProjects: Int,
        acceptedContractPeriods: Int,
        resolvedContractPeriods: Int,
        silentMisses: Int,
        incompleteReviews: Int,
        projectsWithProofSequences: Int,
        projectFacts: [ProjectHealthFact]
    ) {
        self.eligibleProjects = eligibleProjects
        self.canonicalStepProjects = canonicalStepProjects
        self.acceptedContractPeriods = acceptedContractPeriods
        self.resolvedContractPeriods = resolvedContractPeriods
        self.silentMisses = silentMisses
        self.incompleteReviews = incompleteReviews
        self.projectsWithProofSequences = projectsWithProofSequences
        self.projectFacts = projectFacts
    }
}

public struct ProductHealthService: Sendable {
    public init() {}

    public func report(snapshot: JournalSnapshot, now: Date = Date()) -> ProductHealthReport {
        let eligible = snapshot.projects.filter {
            $0.deletedAt == nil && [.active, .lowFrequency, .paused].contains($0.status)
        }
        let contractsByProject = Dictionary(
            grouping: snapshot.evidenceContracts.filter { $0.deletedAt == nil },
            by: \.projectId
        )
        let proofsByProject = Dictionary(
            grouping: snapshot.proofs.filter { $0.deletedAt == nil },
            by: \.projectId
        )
        let revisionCounts = Dictionary(
            grouping: snapshot.proofRevisions.filter { $0.deletedAt == nil },
            by: \.proofId
        ).mapValues(\.count)

        let facts = eligible.map { project -> ProjectHealthFact in
            let contractFacts = contractsByProject[project.id, default: []].map {
                periodFact(contract: $0, snapshot: snapshot, now: now)
            }
            let proofSequence = proofsByProject[project.id, default: []].contains {
                revisionCounts[$0.id, default: 0] >= 2
            }
            return ProjectHealthFact(
                projectId: project.id,
                hasCanonicalStep: !project.currentNextStep.trimmedForJournal.isEmpty,
                acceptedContractPeriods: contractFacts.reduce(0) { $0 + $1.accepted },
                resolvedContractPeriods: contractFacts.reduce(0) { $0 + $1.resolved },
                silentMisses: contractFacts.reduce(0) { $0 + $1.silent },
                hasProofSequence: proofSequence
            )
        }.sorted { $0.projectId.uuidString < $1.projectId.uuidString }

        return ProductHealthReport(
            eligibleProjects: facts.count,
            canonicalStepProjects: facts.filter(\.hasCanonicalStep).count,
            acceptedContractPeriods: facts.reduce(0) { $0 + $1.acceptedContractPeriods },
            resolvedContractPeriods: facts.reduce(0) { $0 + $1.resolvedContractPeriods },
            silentMisses: facts.reduce(0) { $0 + $1.silentMisses },
            incompleteReviews: snapshot.reviews.filter {
                $0.deletedAt == nil && $0.confirmedDecisionIds.isEmpty
            }.count,
            projectsWithProofSequences: facts.filter(\.hasProofSequence).count,
            projectFacts: facts
        )
    }

    private func periodFact(
        contract: EvidenceContract,
        snapshot: JournalSnapshot,
        now: Date
    ) -> (accepted: Int, resolved: Int, silent: Int) {
        guard case let .interval(days) = contract.trigger else {
            return (0, 0, 0)
        }
        let end = min(contract.endedAt ?? now, now)
        let expected = max(0, Int(end.timeIntervalSince(contract.startsAt) / TimeInterval(days * 86_400)))
        let accepted = min(expected, snapshot.evidenceAcceptances.filter {
            $0.contractId == contract.id && $0.deletedAt == nil && $0.acceptedAt <= end
        }.count)
        let resolvingKinds: Set<ReviewDecisionKind> = [
            .reviseContract, .changeFrequency, .pause, .archive, .complete
        ]
        let resolutions = snapshot.reviewDecisions.filter {
            $0.projectId == contract.projectId
                && $0.deletedAt == nil
                && $0.decidedAt >= contract.startsAt
                && $0.decidedAt <= end
                && resolvingKinds.contains($0.kind)
        }.count
        let unresolved = max(0, expected - accepted)
        let resolved = min(unresolved, resolutions)
        return (accepted, resolved, max(0, unresolved - resolved))
    }
}
