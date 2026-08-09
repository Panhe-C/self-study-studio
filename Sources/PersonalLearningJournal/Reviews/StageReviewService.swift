import Foundation

public enum StageReviewError: Error, Equatable, Sendable {
    case missingProject
    case missingPhase
    case missingReview
    case notStageReview
    case alreadyPublished
    case invalidDecision
    case missingQualifyingProof
    case missingEvidenceContract
    case proofDoesNotQualify
    case missingProofRevision
    case staleRevision
}

extension StageReviewError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingProject: "This Project is no longer available."
        case .missingPhase: "This Plan Phase is no longer available."
        case .missingReview: "This Stage Review is no longer available."
        case .notStageReview: "This Review is not a Stage Review."
        case .alreadyPublished: "This Stage Review has already been published."
        case .invalidDecision: "Confirm a valid Stage Review decision."
        case .missingQualifyingProof: "Accept explicit Qualifying Proof before advancing the Phase."
        case .missingEvidenceContract: "Add an Evidence Contract before accepting Qualifying Proof."
        case .proofDoesNotQualify: "The selected Proof has no inspectable qualifying artifact."
        case .missingProofRevision: "The selected Proof revision is unavailable."
        case .staleRevision: "Refresh this Stage Review before publishing it."
        }
    }
}

/// Local-first publication service for project-scoped Stage Reviews. A single
/// JournalTransaction carries the review, decision, proof linkage, phase /
/// project transition, and Trail events so the repository cannot expose a
/// partially published decision.
public final class StageReviewService {
    private let repository: any JournalRepository
    private let readinessService: StageReviewReadinessService
    private let now: () -> Date

    public init(
        repository: any JournalRepository,
        readinessService: StageReviewReadinessService = StageReviewReadinessService(),
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.readinessService = readinessService
        self.now = now
    }

    public func readiness(
        projectID: UUID,
        phaseID: UUID,
        at date: Date = Date(),
        requested: Bool = false
    ) throws -> StageReviewReadiness {
        let snapshot = try repository.snapshot()
        guard snapshot.projects.contains(where: { $0.id == projectID && $0.deletedAt == nil }) else {
            throw StageReviewError.missingProject
        }
        guard snapshot.planPhases.contains(where: { $0.id == phaseID && $0.deletedAt == nil }) else {
            throw StageReviewError.missingPhase
        }
        return readinessService.evaluate(
            projectID: projectID,
            phaseID: phaseID,
            snapshot: snapshot,
            at: date,
            requested: requested
        )
    }

    @discardableResult
    public func openStageReview(
        projectID: UUID,
        phaseID: UUID,
        at date: Date? = nil
    ) throws -> Review {
        let snapshot = try repository.snapshot()
        guard snapshot.projects.contains(where: { $0.id == projectID && $0.deletedAt == nil }) else {
            throw StageReviewError.missingProject
        }
        guard let phase = snapshot.planPhases.first(where: { $0.id == phaseID && $0.deletedAt == nil }) else {
            throw StageReviewError.missingPhase
        }
        guard let plan = snapshot.coursePlans.first(where: { $0.id == phase.planId && $0.deletedAt == nil }) else {
            throw StageReviewError.missingPhase
        }
        if let existing = snapshot.reviews.first(where: {
            $0.scope == .stage && $0.projectId == projectID && $0.phaseId == phaseID && $0.deletedAt == nil && $0.status == .draft
        }) {
            return existing
        }

        let createdAt = date ?? now()
        let readiness = readinessService.evaluate(
            projectID: projectID,
            phaseID: phaseID,
            snapshot: snapshot,
            at: createdAt,
            requested: true
        )
        let review = Review(
            scope: .stage,
            projectId: projectID,
            phaseId: phaseID,
            status: .draft,
            periodStart: phase.targetStart,
            periodEnd: phase.targetEnd,
            facts: readiness.facts,
            patterns: [],
            decisions: [],
            projectRecommendations: [:],
            nextSteps: [:],
            aiSourceSummary: [],
            sourceReferences: readiness.sourceReferences,
            createdAt: createdAt,
            updatedAt: createdAt,
            confirmedDecisionIds: [],
            referencedProofRevisionIds: [],
            publishedAt: nil
        )
        // Keep the plan reference in the validation path so opening a review
        // never creates a draft for a phase that is not attached to a plan.
        _ = plan
        try repository.commit(
            JournalTransaction(
                upserts: [.review(review)],
                origin: .user,
                revisionExpectations: [review.reference: .newRecord()]
            )
        )
        return review
    }

    public func revisionGuardExpectation(for reviewID: UUID) throws -> RevisionGuardExpectation {
        let snapshot = try repository.snapshot()
        guard let review = snapshot.reviews.first(where: { $0.id == reviewID }) else {
            throw StageReviewError.missingReview
        }
        if let metadata = try repository.metadata(for: review.reference) {
            return .existingTarget(revisionID: review.id, recordChangeTag: metadata.recordChangeTag)
        }
        return .newRecord()
    }

    @discardableResult
    public func publishStageReview(
        reviewID: UUID,
        decision: ReviewDecision,
        qualifyingProofID: UUID?,
        acceptedCriteria: [String],
        expectation: RevisionGuardExpectation
    ) throws -> Review {
        let snapshot = try repository.snapshot()
        guard let reviewIndex = snapshot.reviews.firstIndex(where: { $0.id == reviewID }) else {
            throw StageReviewError.missingReview
        }
        let review = snapshot.reviews[reviewIndex]
        guard review.scope == .stage, let projectID = review.projectId, let phaseID = review.phaseId else {
            throw StageReviewError.notStageReview
        }
        guard review.status == .draft else { throw StageReviewError.alreadyPublished }
        guard decision.reviewId == reviewID,
              decision.projectId == projectID,
              decision.phaseId == phaseID else {
            throw StageReviewError.invalidDecision
        }
        guard [.continueUnchanged, .advancePhase, .extendPhase, .revisePhase, .pause, .abandon]
            .contains(decision.kind) else {
            throw StageReviewError.invalidDecision
        }

        let advancesPhase = decision.kind == .advancePhase
        var upserts: [JournalEntity] = []
        var published = review
        let publishedAt = now()
        var linkedAcceptanceID: UUID?
        var linkedProofRevisionID: UUID?
        var planRevisionDraftID: UUID?

        if advancesPhase {
            guard let qualifyingProofID else { throw StageReviewError.missingQualifyingProof }
            guard let project = snapshot.projects.first(where: { $0.id == projectID }) else {
                throw StageReviewError.missingProject
            }
            guard let phase = snapshot.planPhases.first(where: { $0.id == phaseID }) else {
                throw StageReviewError.missingPhase
            }
            guard let proof = snapshot.proofs.first(where: {
                $0.id == qualifyingProofID && $0.projectId == projectID && $0.deletedAt == nil
            }), proof.qualifies else {
                throw StageReviewError.proofDoesNotQualify
            }
            let criteria = acceptedCriteria.map(\.trimmedForJournal).filter { !$0.isEmpty }
            guard !criteria.isEmpty else { throw StageReviewError.missingQualifyingProof }
            guard let contractID = project.activeEvidenceContractId else {
                throw StageReviewError.missingEvidenceContract
            }
            let proofRevision = try proofRevision(for: proof, snapshot: snapshot, at: publishedAt)
            linkedProofRevisionID = proofRevision.id
            let acceptance = EvidenceAcceptance(
                contractId: contractID,
                proofId: proof.id,
                phaseId: phaseID,
                reviewId: reviewID,
                proofRevisionId: proofRevision.id,
                acceptedCriteria: criteria,
                acceptedAt: publishedAt
            )
            linkedAcceptanceID = acceptance.id
            upserts.append(.proofRevision(proofRevision))
            upserts.append(.evidenceAcceptance(acceptance))

            var completedPhase = phase
            completedPhase.progress = .completed
            upserts.append(.planPhase(completedPhase))

            let siblingPhases = snapshot.planPhases
                .filter { $0.planId == phase.planId && $0.id != phase.id && $0.deletedAt == nil }
                .sorted { ($0.ordinal, $0.id.uuidString) < ($1.ordinal, $1.id.uuidString) }
            if let next = siblingPhases.first(where: { $0.ordinal > phase.ordinal }) {
                var activeNext = next
                activeNext.progress = .active
                upserts.append(.planPhase(activeNext))
            } else if let projectIndex = snapshot.projects.firstIndex(where: { $0.id == projectID }) {
                var completedProject = snapshot.projects[projectIndex]
                completedProject.status = .completed
                completedProject.completedAt = publishedAt
                completedProject.updatedAt = publishedAt
                upserts.append(.project(completedProject))
            }
        } else if decision.kind == .extendPhase || decision.kind == .revisePhase {
            guard let phase = snapshot.planPhases.first(where: { $0.id == phaseID }),
                  let plan = snapshot.coursePlans.first(where: { $0.id == phase.planId && $0.status == .active }) else {
                throw StageReviewError.missingPhase
            }
            let revisionDraft = try makePlanRevisionDraft(
                from: plan,
                phaseID: phaseID,
                extend: decision.kind == .extendPhase,
                snapshot: snapshot,
                at: publishedAt
            )
            planRevisionDraftID = revisionDraft.id
            upserts.append(contentsOf: revisionDraft.entities)
        } else if decision.kind == .pause || decision.kind == .abandon {
            guard let projectIndex = snapshot.projects.firstIndex(where: {
                $0.id == projectID && $0.deletedAt == nil
            }) else {
                throw StageReviewError.missingProject
            }
            var changedProject = snapshot.projects[projectIndex]
            changedProject.status = decision.kind == .pause ? .paused : .abandoned
            changedProject.updatedAt = publishedAt
            changedProject.archivedAt = decision.kind == .abandon ? publishedAt : nil
            changedProject.completedAt = nil
            upserts.append(.project(changedProject))
        } else if !decision.isValid {
            throw StageReviewError.invalidDecision
        }

        var publishedDecision = decision
        publishedDecision.qualifyingProofAcceptanceId = linkedAcceptanceID
        publishedDecision.planRevisionDraftId = planRevisionDraftID ?? decision.planRevisionDraftId
        published.confirmedDecisionIds.append(publishedDecision.id)
        if let linkedProofRevisionID {
            published.referencedProofRevisionIds.append(linkedProofRevisionID)
        }
        published.status = .published
        published.publishedAt = publishedAt
        published.updatedAt = publishedAt

        let reviewEvent = TrailEvent(
            projectId: projectID,
            type: .review,
            sourceId: reviewID,
            occurredAt: publishedAt,
            title: "Stage Review published",
            detail: decision.kind.rawValue
        )
        upserts.insert(.review(published), at: 0)
        upserts.append(.reviewDecision(publishedDecision))
        upserts.append(.trailEvent(reviewEvent))

        var expectations: [JournalEntityReference: RevisionGuardExpectation] = [:]
        if expectation.recordState == .existingRecord,
           let metadata = try repository.metadata(for: review.reference) {
            do {
                try RevisionGuard.validate(
                    expectation: expectation,
                    currentRevisionID: review.id,
                    currentRecordChangeTag: metadata.recordChangeTag
                )
            } catch {
                throw StageReviewError.staleRevision
            }
            expectations[review.reference] = expectation
        } else if expectation.recordState == .newRecord {
            // A freshly opened draft has no server metadata yet. Keep the new
            // target guard in the local outbox; CloudKit will reject a remote
            // collision instead of silently overwriting it.
            expectations[review.reference] = expectation
        }
        for entity in upserts where entity.reference != review.reference {
            if let metadata = try repository.metadata(for: entity.reference) {
                expectations[entity.reference] = .existingTarget(
                    revisionID: entity.reference.id,
                    recordChangeTag: metadata.recordChangeTag
                )
            } else if entity.reference.kind == .coursePlan || entity.reference.kind == .planPhase
                || entity.reference.kind == .plannedSession || entity.reference.kind == .practiceRoutine {
                expectations[entity.reference] = .newRecord()
            }
        }
        try repository.commit(
            JournalTransaction(
                upserts: upserts,
                origin: .user,
                transactionID: reviewID,
                revisionExpectations: expectations
            )
        )
        return published
    }

    private func proofRevision(
        for proof: Proof,
        snapshot: JournalSnapshot,
        at timestamp: Date
    ) throws -> ProofRevision {
        if let existing = snapshot.proofRevisions
            .filter({ $0.proofId == proof.id && $0.revision == proof.revision && $0.deletedAt == nil })
            .max(by: { $0.createdAt < $1.createdAt }) {
            return existing
        }
        let checksum = try JSONEncoder.journal.encode(proof.artifact).base64EncodedString()
        return ProofRevision(
            proof: proof,
            revision: proof.revision,
            artifactChecksum: checksum,
            createdAt: timestamp
        )
    }

    private struct RevisionDraftPayload {
        let id: UUID
        let entities: [JournalEntity]
    }

    private func makePlanRevisionDraft(
        from plan: LearningPlan,
        phaseID: UUID,
        extend: Bool,
        snapshot: JournalSnapshot,
        at timestamp: Date
    ) throws -> RevisionDraftPayload {
        let nextRevision = snapshot.coursePlans
            .filter { $0.projectId == plan.projectId && $0.planSeriesID == plan.planSeriesID }
            .map(\.revision)
            .max()
            .map { $0 + 1 } ?? (plan.revision + 1)
        let draft = try LearningPlan(
            projectId: plan.projectId,
            revision: nextRevision,
            planSeriesID: plan.planSeriesID,
            baseRevisionID: plan.revisionID,
            supersedesID: plan.revisionID,
            status: .draft,
            courseURL: plan.courseURL,
            courseTitle: plan.courseTitle,
            courseOutline: plan.courseOutline,
            goal: plan.goal,
            expectedOutcome: plan.expectedOutcome,
            startsOn: plan.startsOn,
            deadline: plan.deadline,
            weeklyBudgetMinutes: plan.weeklyBudgetMinutes,
            summary: plan.summary,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        let phases = snapshot.planPhases.filter { $0.planId == plan.id && $0.deletedAt == nil }
        var phaseIDs: [UUID: UUID] = [:]
        var draftPhases: [PlanPhase] = []
        for source in phases.sorted(by: { ($0.ordinal, $0.id.uuidString) < ($1.ordinal, $1.id.uuidString) }) {
            let id = UUID()
            phaseIDs[source.id] = id
            var value = source
            value.id = id
            value.planId = draft.id
            value.planRevisionID = draft.revisionID
            value.planSeriesID = draft.planSeriesID
            value.isStructuralLocked = false
            value.createdAt = timestamp
            value.updatedAt = timestamp
            if extend && source.id == phaseID {
                value.targetEnd = value.targetEnd.addingTimeInterval(7 * 86_400)
            }
            draftPhases.append(value)
        }

        var draftSessions: [PlannedSession] = []
        for source in snapshot.plannedSessions where source.planId == plan.id && source.deletedAt == nil {
            guard let draftPhaseID = phaseIDs[source.phaseId] else { continue }
            var value = source
            value.id = UUID()
            value.planId = draft.id
            value.planRevisionID = draft.revisionID
            value.planSeriesID = draft.planSeriesID
            value.isStructuralLocked = false
            value.phaseId = draftPhaseID
            value.createdAt = timestamp
            value.updatedAt = timestamp
            draftSessions.append(value)
        }

        var draftRoutines: [PracticeRoutine] = []
        for source in snapshot.practiceRoutines where source.planRevisionID == plan.revisionID && source.deletedAt == nil {
            var value = source
            value.id = UUID()
            value.planRevisionID = draft.revisionID
            value.planSeriesID = draft.planSeriesID
            value.isStructuralLocked = false
            value.createdAt = timestamp
            value.updatedAt = timestamp
            draftRoutines.append(value)
        }

        return RevisionDraftPayload(
            id: draft.id,
            entities: [.coursePlan(draft)]
                + draftPhases.map(JournalEntity.planPhase)
                + draftSessions.map(JournalEntity.plannedSession)
                + draftRoutines.map(JournalEntity.practiceRoutine)
        )
    }
}

private extension Review {
    var reference: JournalEntityReference { JournalEntityReference(.review, id) }
}
