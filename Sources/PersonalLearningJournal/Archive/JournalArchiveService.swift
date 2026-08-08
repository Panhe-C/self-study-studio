import CryptoKit
import Foundation

public enum JournalArchiveError: Error, Equatable, Sendable {
    case unencryptedExportRequiresConfirmation
    case passwordRequired
    case invalidArchive
    case unsupportedFormatVersion(Int)
    case checksumMismatch
    case duplicateIdentifiers
    case unsafeAttachmentPath(String)
    case missingAttachment(String)
    case attachmentDeletionFailed([String])
    case projectNotPurged(UUID)
}

public struct JournalArchiveManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var createdAt: Date
    public var recordCounts: [String: Int]
    public var checksums: [String: String]
}

public struct JournalArchiveEnvelope: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var salt: Data?
    public var derivationRounds: Int?
    public var sealedPayload: Data
    public var encrypted: Bool
}

public struct JournalArchivePreview: Equatable, Sendable {
    public var manifest: JournalArchiveManifest
    public var snapshot: JournalSnapshot
    public var attachmentData: [String: Data]
    public var duplicateIDs: Set<UUID>
    public var checksumsValid: Bool
}

public struct JournalArchiveRestore: Equatable, Sendable {
    public var snapshot: JournalSnapshot
    public var attachmentData: [String: Data]
}

public struct TrashPurgeImpact: Equatable, Sendable {
    public var projectID: UUID
    public var sessionCount: Int
    public var proofCount: Int
    public var contractCount: Int
    public var acceptanceCount: Int
    public var revisionCount: Int
    public var reviewCount: Int
    public var reviewUpdateCount: Int
    public var decisionCount: Int
    public var trailCount: Int
    public var planCount: Int
    public var phaseCount: Int
    public var plannedSessionCount: Int
    public var routineCount: Int
    public var practiceSessionCount: Int
    public var attachmentPaths: [String]
    public var references: [JournalEntityReference]
    public var reviewUpdates: [Review]
}

enum JournalReviewScopeMode: Equatable {
    case removingProject
    case exportingProject
}

enum JournalReviewAttribution: Equatable {
    case targetOnly
    case otherOnly
    case mixed
    case unknown
}

private struct JournalReviewScopeContext {
    let targetProjectID: UUID
    private let sourceOwners: [String: UUID]

    init(snapshot: JournalSnapshot, targetProjectID: UUID) {
        self.targetProjectID = targetProjectID
        var owners: [String: UUID] = [:]
        func add(_ kind: String, _ id: UUID, owner: UUID?) {
            guard let owner else { return }
            owners["\(kind) \(id.uuidString.prefix(8))"] = owner
        }

        for project in snapshot.projects {
            add("project", project.id, owner: project.id)
        }
        for session in snapshot.sessions {
            add("session", session.id, owner: session.projectId)
        }
        for proof in snapshot.proofs {
            add("proof", proof.id, owner: proof.projectId)
        }
        let planOwners = Dictionary(uniqueKeysWithValues: snapshot.coursePlans.map { ($0.id, $0.projectId) })
        for plan in snapshot.coursePlans {
            add("plan", plan.id, owner: plan.projectId)
        }
        for phase in snapshot.planPhases {
            add("phase", phase.id, owner: planOwners[phase.planId])
        }
        for plannedSession in snapshot.plannedSessions {
            add("plannedSession", plannedSession.id, owner: plannedSession.projectId)
        }
        let routineOwners = Dictionary(uniqueKeysWithValues: snapshot.practiceRoutines.compactMap { routine in
            routine.projectId.map { (routine.id, $0) }
        })
        for routine in snapshot.practiceRoutines {
            add("routine", routine.id, owner: routine.projectId)
        }
        for session in snapshot.practiceSessions {
            add("practice", session.id, owner: session.linkedProjectId ?? routineOwners[session.routineId])
        }
        let proofOwners = Dictionary(uniqueKeysWithValues: snapshot.proofs.map { ($0.id, $0.projectId) })
        for revision in snapshot.proofRevisions {
            add("revision", revision.id, owner: proofOwners[revision.proofId])
        }
        for decision in snapshot.reviewDecisions {
            add("decision", decision.id, owner: decision.projectId)
        }
        for event in snapshot.trailEvents {
            add("trail", event.id, owner: event.projectId)
        }
        self.sourceOwners = owners
    }

    func attribution(for sources: [String]?) -> JournalReviewAttribution {
        guard let sources, !sources.isEmpty else { return .unknown }
        var sawTarget = false
        var sawOther = false
        var sawUnknown = false
        for source in sources {
            let owners = Set(sourceOwners.compactMap { token, owner in
                source.contains(token) ? owner : nil
            })
            let hasTarget = owners.contains(targetProjectID)
            let hasOther = owners.contains { $0 != targetProjectID }
            if hasTarget && hasOther {
                return .mixed
            }
            if hasTarget {
                sawTarget = true
            } else if hasOther {
                sawOther = true
            } else {
                sawUnknown = true
            }
        }
        if sawTarget && sawOther { return .mixed }
        if sawTarget && !sawUnknown { return .targetOnly }
        if sawOther && !sawUnknown { return .otherOnly }
        return .unknown
    }

    func attribution(
        for value: String,
        references: [String: [String]]?
    ) -> JournalReviewAttribution {
        let direct = attribution(for: [value])
        let referenced = references?[value] ?? []
        guard !referenced.isEmpty else { return direct }
        guard direct != .unknown else { return attribution(for: referenced) }
        return attribution(for: [value] + referenced)
    }
}

private struct JournalArchivePayload: Codable {
    var manifest: JournalArchiveManifest
    var snapshot: JournalSnapshot
    var attachments: [String: Data]
}

public struct JournalArchiveService {
    public static let formatVersion = 1

    private let now: () -> Date
    private let derivationRounds: Int
    private let removeAttachment: (String) throws -> Void
    private let cleanupQueue: AttachmentCleanupQueue?

    public init(
        now: @escaping () -> Date = Date.init,
        derivationRounds: Int = 10_000,
        removeAttachment: @escaping (String) throws -> Void = AttachmentStore.removeAttachmentFile,
        cleanupQueue: AttachmentCleanupQueue? = nil
    ) {
        self.now = now
        self.derivationRounds = max(1, derivationRounds)
        self.removeAttachment = removeAttachment
        self.cleanupQueue = cleanupQueue
    }

    public func export(
        snapshot: JournalSnapshot,
        attachments: [String: Data],
        password: String?,
        allowUnencrypted: Bool = false
    ) throws -> JournalArchiveEnvelope {
        guard duplicateIDs(in: snapshot).isEmpty else {
            throw JournalArchiveError.duplicateIdentifiers
        }
        try validateRelationships(in: snapshot)
        try validateAttachmentPaths(attachments.keys)
        let snapshotData = try Self.encoder.encode(snapshot)
        var checksums = ["snapshot.json": Self.digest(snapshotData)]
        for (path, data) in attachments {
            checksums["attachment:\(path)"] = Self.digest(data)
        }
        let manifest = JournalArchiveManifest(
            formatVersion: Self.formatVersion,
            createdAt: now(),
            recordCounts: recordCounts(snapshot),
            checksums: checksums
        )
        let payload = try Self.encoder.encode(
            JournalArchivePayload(manifest: manifest, snapshot: snapshot, attachments: attachments)
        )

        guard let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard allowUnencrypted else {
                throw JournalArchiveError.unencryptedExportRequiresConfirmation
            }
            return JournalArchiveEnvelope(
                formatVersion: Self.formatVersion,
                salt: nil,
                derivationRounds: nil,
                sealedPayload: payload,
                encrypted: false
            )
        }

        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = Self.deriveKey(password: password, salt: salt, rounds: derivationRounds)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw JournalArchiveError.invalidArchive }
        return JournalArchiveEnvelope(
            formatVersion: Self.formatVersion,
            salt: salt,
            derivationRounds: derivationRounds,
            sealedPayload: combined,
            encrypted: true
        )
    }

    public func preview(
        _ envelope: JournalArchiveEnvelope,
        password: String?
    ) throws -> JournalArchivePreview {
        guard envelope.formatVersion == Self.formatVersion else {
            throw JournalArchiveError.unsupportedFormatVersion(envelope.formatVersion)
        }
        let payloadData: Data
        if envelope.encrypted {
            guard let password, let salt = envelope.salt, let rounds = envelope.derivationRounds else {
                throw JournalArchiveError.passwordRequired
            }
            do {
                let box = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
                payloadData = try AES.GCM.open(
                    box,
                    using: Self.deriveKey(password: password, salt: salt, rounds: rounds)
                )
            } catch {
                throw JournalArchiveError.invalidArchive
            }
        } else {
            payloadData = envelope.sealedPayload
        }

        let payload: JournalArchivePayload
        do {
            payload = try Self.decoder.decode(JournalArchivePayload.self, from: payloadData)
        } catch {
            throw JournalArchiveError.invalidArchive
        }
        guard payload.manifest.formatVersion == Self.formatVersion else {
            throw JournalArchiveError.unsupportedFormatVersion(payload.manifest.formatVersion)
        }
        try validateAttachmentPaths(payload.attachments.keys)
        let checksumsValid = try checksumsAreValid(payload)
        guard checksumsValid else { throw JournalArchiveError.checksumMismatch }
        guard payload.manifest.recordCounts == recordCounts(payload.snapshot) else {
            throw JournalArchiveError.invalidArchive
        }
        try validateRelationships(in: payload.snapshot)

        return JournalArchivePreview(
            manifest: payload.manifest,
            snapshot: payload.snapshot,
            attachmentData: payload.attachments,
            duplicateIDs: duplicateIDs(in: payload.snapshot),
            checksumsValid: checksumsValid
        )
    }

    public func restore(_ preview: JournalArchivePreview) throws -> JournalArchiveRestore {
        guard preview.checksumsValid else { throw JournalArchiveError.checksumMismatch }
        guard preview.duplicateIDs.isEmpty else { throw JournalArchiveError.duplicateIdentifiers }
        try validateRelationships(in: preview.snapshot)
        return JournalArchiveRestore(snapshot: preview.snapshot, attachmentData: preview.attachmentData)
    }

    public func restore(
        _ preview: JournalArchivePreview,
        into repository: any JournalRepository
    ) throws {
        let restored = try restore(preview)
        try repository.commit(
            JournalTransaction(
                upserts: Self.entities(in: restored.snapshot),
                origin: .migration,
                stateMetadata: JournalStateMetadata(snapshot: restored.snapshot)
            )
        )
    }

    /// Returns a review with only the selected project's content for a scoped
    /// export, or with that project's content removed for a permanent purge.
    /// Free text without an unambiguous source is replaced with a redacted
    /// placeholder rather than guessed into another project's history.
    static func scopedReview(
        _ review: Review,
        projectID: UUID,
        snapshot: JournalSnapshot,
        mode: JournalReviewScopeMode
    ) -> Review? {
        let context = JournalReviewScopeContext(snapshot: snapshot, targetProjectID: projectID)
        let targetDecisionIDs = Set(snapshot.reviewDecisions.compactMap { decision in
            decision.reviewId == review.id && decision.projectId == projectID ? decision.id : nil
        })
        let targetProofIDs = Set(snapshot.proofs.filter { $0.projectId == projectID }.map(\.id))
        let targetRevisionIDs = Set(snapshot.proofRevisions.compactMap { revision in
            targetProofIDs.contains(revision.proofId) ? revision.id : nil
        })
        let survivingDecisionIDs = Set(snapshot.reviewDecisions.compactMap { decision in
            decision.reviewId == review.id && decision.projectId != projectID ? decision.id : nil
        })

        var scoped = review
        switch mode {
        case .removingProject:
            scoped.projectRecommendations = review.projectRecommendations.filter { $0.key != projectID }
            scoped.nextSteps = review.nextSteps.filter { $0.key != projectID }
        case .exportingProject:
            scoped.projectRecommendations = review.projectRecommendations.filter { $0.key == projectID }
            scoped.nextSteps = review.nextSteps.filter { $0.key == projectID }
        }

        scoped.facts = scopedInsights(
            review.facts,
            references: review.sourceReferences,
            context: context,
            mode: mode
        )
        scoped.patterns = scopedInsights(
            review.patterns,
            references: review.sourceReferences,
            context: context,
            mode: mode
        )
        scoped.decisions = scopedInsights(
            review.decisions,
            references: review.sourceReferences,
            context: context,
            mode: mode
        )
        scoped.aiSourceSummary = scopedInsights(
            review.aiSourceSummary,
            references: review.sourceReferences,
            context: context,
            mode: mode
        )
        let keepAttribution: JournalReviewAttribution = mode == .removingProject ? .otherOnly : .targetOnly
        scoped.sourceReferences = review.sourceReferences.reduce(into: [:]) { result, entry in
            let attribution = context.attribution(for: entry.value)
            guard attribution == keepAttribution else { return }
            result[entry.key] = entry.value
        }

        switch mode {
        case .removingProject:
            scoped.confirmedDecisionIds = review.confirmedDecisionIds.filter { decisionID in
                !targetDecisionIDs.contains(decisionID)
                    && snapshot.reviewDecisions.contains { decision in
                        decision.id == decisionID && decision.reviewId == review.id
                    }
            }
            scoped.referencedProofRevisionIds = review.referencedProofRevisionIds.filter { revisionID in
                !targetRevisionIDs.contains(revisionID)
                    && snapshot.proofRevisions.contains { revision in revision.id == revisionID }
            }
        case .exportingProject:
            scoped.confirmedDecisionIds = review.confirmedDecisionIds.filter { targetDecisionIDs.contains($0) }
            scoped.referencedProofRevisionIds = review.referencedProofRevisionIds.filter { targetRevisionIDs.contains($0) }
        }

        let hasRemainingContent = !scoped.facts.isEmpty
            || !scoped.patterns.isEmpty
            || !scoped.decisions.isEmpty
            || !scoped.projectRecommendations.isEmpty
            || !scoped.nextSteps.isEmpty
            || !scoped.aiSourceSummary.isEmpty
            || !scoped.sourceReferences.isEmpty
            || !scoped.confirmedDecisionIds.isEmpty
            || !scoped.referencedProofRevisionIds.isEmpty
            || !survivingDecisionIDs.isEmpty
        if mode == .removingProject, !hasRemainingContent {
            return nil
        }
        return scoped
    }

    private static let redactedReviewInsight = "[redacted project insight]"

    private static func scopedInsights(
        _ values: [String],
        references: [String: [String]]?,
        context: JournalReviewScopeContext,
        mode: JournalReviewScopeMode
    ) -> [String] {
        var result: [String] = []
        var needsRedaction = false
        for value in values {
            let attribution = context.attribution(for: value, references: references)
            let keep: Bool
            switch mode {
            case .removingProject: keep = attribution == .otherOnly
            case .exportingProject: keep = attribution == .targetOnly
            }
            if keep {
                result.append(value)
            } else if attribution == .unknown || attribution == .mixed {
                needsRedaction = true
            }
        }
        if needsRedaction && !result.contains(redactedReviewInsight) {
            result.append(redactedReviewInsight)
        }
        return result
    }

    static func reviewTouchesProject(
        _ review: Review,
        projectID: UUID,
        snapshot: JournalSnapshot
    ) -> Bool {
        if review.projectRecommendations[projectID] != nil || review.nextSteps[projectID] != nil {
            return true
        }
        let targetDecisionIDs = Set(snapshot.reviewDecisions.compactMap { decision in
            decision.reviewId == review.id && decision.projectId == projectID ? decision.id : nil
        })
        if !targetDecisionIDs.isEmpty
            || !targetDecisionIDs.isDisjoint(with: review.confirmedDecisionIds) {
            return true
        }
        let targetProofIDs = Set(snapshot.proofs.filter { $0.projectId == projectID }.map(\.id))
        let targetRevisionIDs = Set(snapshot.proofRevisions.compactMap { revision in
            targetProofIDs.contains(revision.proofId) ? revision.id : nil
        })
        if !targetRevisionIDs.isDisjoint(with: review.referencedProofRevisionIds) {
            return true
        }
        let context = JournalReviewScopeContext(snapshot: snapshot, targetProjectID: projectID)
        let allInsights = review.facts + review.patterns + review.decisions + review.aiSourceSummary
        return allInsights.contains {
            let attribution = context.attribution(for: $0, references: review.sourceReferences)
            return attribution == .targetOnly || attribution == .mixed
        } || review.sourceReferences.values.contains {
            let attribution = context.attribution(for: $0)
            return attribution == .targetOnly || attribution == .mixed
        }
    }

    public func purgeImpact(projectID: UUID, snapshot: JournalSnapshot) -> TrashPurgeImpact {
        let sessions = snapshot.sessions.filter { $0.projectId == projectID }
        let sessionIDs = Set(sessions.map(\.id))
        let proofs = snapshot.proofs.filter { $0.projectId == projectID || $0.sessionId.map(sessionIDs.contains) == true }
        let proofIDs = Set(proofs.map(\.id))
        let contracts = snapshot.evidenceContracts.filter { $0.projectId == projectID }
        let contractIDs = Set(contracts.map(\.id))
        let acceptances = snapshot.evidenceAcceptances.filter {
            contractIDs.contains($0.contractId) || proofIDs.contains($0.proofId)
        }
        let revisions = snapshot.proofRevisions.filter { proofIDs.contains($0.proofId) }
        let reviews = snapshot.reviews.filter {
            Self.reviewTouchesProject($0, projectID: projectID, snapshot: snapshot)
        }
        let decisions = snapshot.reviewDecisions.filter { $0.projectId == projectID }
        let deletedReviews = reviews.compactMap { review -> Review? in
            Self.scopedReview(
                review,
                projectID: projectID,
                snapshot: snapshot,
                mode: .removingProject
            ) == nil ? review : nil
        }
        let reviewUpdates = reviews.compactMap { review -> Review? in
            guard let scoped = Self.scopedReview(
                review,
                projectID: projectID,
                snapshot: snapshot,
                mode: .removingProject
            ), scoped != review else { return nil }
            return scoped
        }
        let trails = snapshot.trailEvents.filter { $0.projectId == projectID }
        let plans = snapshot.coursePlans.filter { $0.projectId == projectID }
        let planIDs = Set(plans.map(\.id))
        let phases = snapshot.planPhases.filter { planIDs.contains($0.planId) }
        let plannedSessions = snapshot.plannedSessions.filter { $0.projectId == projectID || planIDs.contains($0.planId) }
        let routines = snapshot.practiceRoutines.filter { $0.projectId == projectID }
        let routineIDs = Set(routines.map(\.id))
        let practiceSessions = snapshot.practiceSessions.filter {
            routineIDs.contains($0.routineId) || $0.linkedProjectId == projectID
        }
        var references = [JournalEntityReference(.project, projectID)]
        references += sessions.map { JournalEntityReference(.session, $0.id) }
        references += proofs.map { JournalEntityReference(.proof, $0.id) }
        references += contracts.map { JournalEntityReference(.evidenceContract, $0.id) }
        references += acceptances.map { JournalEntityReference(.evidenceAcceptance, $0.id) }
        references += revisions.map { JournalEntityReference(.proofRevision, $0.id) }
        references += deletedReviews.map { JournalEntityReference(.review, $0.id) }
        references += decisions.map { JournalEntityReference(.reviewDecision, $0.id) }
        references += trails.map { JournalEntityReference(.trailEvent, $0.id) }
        references += plans.map { JournalEntityReference(.coursePlan, $0.id) }
        references += phases.map { JournalEntityReference(.planPhase, $0.id) }
        references += plannedSessions.map { JournalEntityReference(.plannedSession, $0.id) }
        references += routines.map { JournalEntityReference(.practiceRoutine, $0.id) }
        references += practiceSessions.map { JournalEntityReference(.practiceSession, $0.id) }
        return TrashPurgeImpact(
            projectID: projectID,
            sessionCount: sessions.count,
            proofCount: proofs.count,
            contractCount: contracts.count,
            acceptanceCount: acceptances.count,
            revisionCount: revisions.count,
            reviewCount: deletedReviews.count,
            reviewUpdateCount: reviewUpdates.count,
            decisionCount: decisions.count,
            trailCount: trails.count,
            planCount: plans.count,
            phaseCount: phases.count,
            plannedSessionCount: plannedSessions.count,
            routineCount: routines.count,
            practiceSessionCount: practiceSessions.count,
            attachmentPaths: proofs.compactMap { proof in
                if let localPath = proof.localPath { return localPath }
                if case let .attachment(localPath, _, _) = proof.artifact { return localPath }
                return nil
            }.sorted(),
            references: references,
            reviewUpdates: reviewUpdates
        )
    }

    @discardableResult
    public func purge(
        projectID: UUID,
        snapshot: JournalSnapshot,
        from repository: any JournalRepository
    ) throws -> TrashPurgeImpact {
        guard snapshot.projects.contains(where: { $0.id == projectID && $0.isTrashed }) else {
            throw JournalArchiveError.invalidArchive
        }
        let impact = purgeImpact(projectID: projectID, snapshot: snapshot)
        try cleanupQueue?.enqueue(projectID: projectID, paths: impact.attachmentPaths)
        try repository.commit(
            JournalTransaction(
                upserts: impact.reviewUpdates.map(JournalEntity.review),
                deletions: impact.references,
                origin: .user
            )
        )
        try retryAttachmentCleanup(
            projectID: projectID,
            paths: impact.attachmentPaths,
            repository: repository
        )
        try cleanupQueue?.remove(projectID: projectID, paths: impact.attachmentPaths)
        return impact
    }

    /// Retries only the file cleanup portion after a repository purge succeeded.
    /// A canonical project tombstone is required before touching any file.
    public func retryAttachmentCleanup(
        projectID: UUID,
        paths: [String],
        repository: any JournalRepository
    ) throws {
        guard try projectIsPurged(projectID: projectID, repository: repository) else {
            throw JournalArchiveError.projectNotPurged(projectID)
        }
        var failedAttachmentPaths: [String] = []
        for path in paths {
            do {
                try removeAttachment(path)
            } catch {
                failedAttachmentPaths.append(path)
            }
        }
        guard failedAttachmentPaths.isEmpty else {
            throw JournalArchiveError.attachmentDeletionFailed(failedAttachmentPaths)
        }
    }

    private func projectIsPurged(
        projectID: UUID,
        repository: any JournalRepository
    ) throws -> Bool {
        guard let entity = try repository.entity(for: .init(.project, projectID)),
              case let .project(project) = entity else {
            return false
        }
        return project.deletedAt != nil && !project.isTrashed
    }

    public func automaticPurgeCandidates(
        snapshot: JournalSnapshot,
        now: Date? = nil,
        retentionDays: Int = 30
    ) -> Set<UUID> {
        let deadline = (now ?? self.now()).addingTimeInterval(-Double(retentionDays) * 86_400)
        return Set(snapshot.projects.compactMap { project in
            guard project.isTrashed, let deletedAt = project.deletedAt, deletedAt <= deadline else { return nil }
            return project.id
        })
    }

    private func checksumsAreValid(_ payload: JournalArchivePayload) throws -> Bool {
        guard payload.manifest.checksums["snapshot.json"] == Self.digest(try Self.encoder.encode(payload.snapshot)) else {
            return false
        }
        let expectedKeys = Set(payload.attachments.keys.map { "attachment:\($0)" })
            .union(["snapshot.json"])
        guard Set(payload.manifest.checksums.keys) == expectedKeys else { return false }
        return payload.attachments.allSatisfy { path, data in
            payload.manifest.checksums["attachment:\(path)"] == Self.digest(data)
        }
    }

    private func validateAttachmentPaths<S: Sequence>(_ paths: S) throws where S.Element == String {
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if path.isEmpty || path.hasPrefix("/") || components.contains("..") || components.contains("") {
                throw JournalArchiveError.unsafeAttachmentPath(path)
            }
        }
    }

    private func validateRelationships(in snapshot: JournalSnapshot) throws {
        let projects = Set(snapshot.projects.map(\.id))
        let sessions = Set(snapshot.sessions.map(\.id))
        let proofs = Set(snapshot.proofs.map(\.id))
        let reviews = Set(snapshot.reviews.map(\.id))
        let contracts = Set(snapshot.evidenceContracts.map(\.id))
        let proofRevisions = Set(snapshot.proofRevisions.map(\.id))
        let decisions = Set(snapshot.reviewDecisions.map(\.id))
        let plans = Set(snapshot.coursePlans.map(\.id))
        let phases = Set(snapshot.planPhases.map(\.id))
        let routines = Set(snapshot.practiceRoutines.map(\.id))
        let allEntityIDs = projects
            .union(sessions)
            .union(proofs)
            .union(reviews)
            .union(contracts)
            .union(snapshot.evidenceAcceptances.map(\.id))
            .union(proofRevisions)
            .union(decisions)
            .union(snapshot.trailEvents.map(\.id))
            .union(plans)
            .union(phases)
            .union(snapshot.plannedSessions.map(\.id))
            .union(snapshot.availabilityRules.map(\.id))
            .union(snapshot.schedulingPreferences.map(\.id))
            .union(routines)
            .union(snapshot.practiceSessions.map(\.id))
        guard snapshot.sessions.allSatisfy({ projects.contains($0.projectId) }) else {
            throw JournalArchiveError.invalidArchive
        }
        guard snapshot.proofs.allSatisfy({ proof in
            projects.contains(proof.projectId) && proof.sessionId.map(sessions.contains) != false
        }) else {
            throw JournalArchiveError.invalidArchive
        }
        guard snapshot.evidenceContracts.allSatisfy({ projects.contains($0.projectId) }),
              snapshot.evidenceAcceptances.allSatisfy({
                  contracts.contains($0.contractId) && proofs.contains($0.proofId)
              }),
              snapshot.proofRevisions.allSatisfy({ proofs.contains($0.proofId) }),
              snapshot.reviews.allSatisfy({ review in
                  review.projectRecommendations.keys.allSatisfy(projects.contains)
                      && review.nextSteps.keys.allSatisfy(projects.contains)
                      && review.confirmedDecisionIds.allSatisfy(decisions.contains)
                      && review.referencedProofRevisionIds.allSatisfy(proofRevisions.contains)
                      && Set(review.sourceReferences.keys).isSubset(
                          of: Set(review.facts + review.patterns + review.decisions + review.aiSourceSummary)
                      )
                      && review.confirmedDecisionIds.allSatisfy { decisionID in
                          snapshot.reviewDecisions.contains {
                              $0.id == decisionID && $0.reviewId == review.id
                          }
                      }
              }),
              snapshot.reviewDecisions.allSatisfy({ decision in
                  reviews.contains(decision.reviewId)
                      && projects.contains(decision.projectId)
                      && decision.contractId.map(contracts.contains) ?? true
                      && decision.capstoneProofId.map(proofs.contains) ?? true
              }),
              snapshot.coursePlans.allSatisfy({ projects.contains($0.projectId) }),
              snapshot.planPhases.allSatisfy({ plans.contains($0.planId) }),
              snapshot.plannedSessions.allSatisfy({ session in
                  plans.contains(session.planId)
                      && phases.contains(session.phaseId)
                      && projects.contains(session.projectId)
                      && session.completedSessionId.map(sessions.contains) ?? true
              }),
              snapshot.practiceRoutines.allSatisfy({ $0.projectId.map(projects.contains) ?? true }),
              snapshot.practiceSessions.allSatisfy({ session in
                  routines.contains(session.routineId)
                      && session.linkedProjectId.map(projects.contains) ?? true
              }),
              snapshot.trailEvents.allSatisfy({
                  projects.contains($0.projectId) && allEntityIDs.contains($0.sourceId)
              }) else {
            throw JournalArchiveError.invalidArchive
        }
    }

    private func duplicateIDs(in snapshot: JournalSnapshot) -> Set<UUID> {
        var duplicates = Set<UUID>()
        func inspect(_ ids: [UUID]) {
            var seen = Set<UUID>()
            for id in ids where !seen.insert(id).inserted { duplicates.insert(id) }
        }
        for ids in Self.identifierGroups(in: snapshot) { inspect(ids) }
        return duplicates
    }

    private func recordCounts(_ snapshot: JournalSnapshot) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: zip(JournalEntityKind.allCases.map(\.rawValue), Self.identifierGroups(in: snapshot).map(\.count)))
    }

    private static func identifierGroups(in snapshot: JournalSnapshot) -> [[UUID]] {
        [snapshot.projects.map(\.id), snapshot.sessions.map(\.id), snapshot.proofs.map(\.id),
         snapshot.reviews.map(\.id), snapshot.evidenceContracts.map(\.id), snapshot.evidenceAcceptances.map(\.id),
         snapshot.proofRevisions.map(\.id), snapshot.reviewDecisions.map(\.id), snapshot.trailEvents.map(\.id),
         snapshot.coursePlans.map(\.id), snapshot.planPhases.map(\.id), snapshot.plannedSessions.map(\.id),
         snapshot.availabilityRules.map(\.id), snapshot.schedulingPreferences.map(\.id),
         snapshot.practiceRoutines.map(\.id), snapshot.practiceSessions.map(\.id)]
    }

    private static func entities(in snapshot: JournalSnapshot) -> [JournalEntity] {
        snapshot.projects.map(JournalEntity.project)
        + snapshot.sessions.map(JournalEntity.session)
        + snapshot.proofs.map(JournalEntity.proof)
        + snapshot.reviews.map(JournalEntity.review)
        + snapshot.evidenceContracts.map(JournalEntity.evidenceContract)
        + snapshot.evidenceAcceptances.map(JournalEntity.evidenceAcceptance)
        + snapshot.proofRevisions.map(JournalEntity.proofRevision)
        + snapshot.reviewDecisions.map(JournalEntity.reviewDecision)
        + snapshot.trailEvents.map(JournalEntity.trailEvent)
        + snapshot.coursePlans.map(JournalEntity.coursePlan)
        + snapshot.planPhases.map(JournalEntity.planPhase)
        + snapshot.plannedSessions.map(JournalEntity.plannedSession)
        + snapshot.availabilityRules.map(JournalEntity.availabilityRule)
        + snapshot.schedulingPreferences.map(JournalEntity.schedulingPreferences)
        + snapshot.practiceRoutines.map(JournalEntity.practiceRoutine)
        + snapshot.practiceSessions.map(JournalEntity.practiceSession)
    }

    private static func deriveKey(password: String, salt: Data, rounds: Int) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var material = passwordData + salt
        for _ in 0..<max(1, rounds) {
            material = Data(SHA256.hash(data: material + passwordData + salt))
        }
        return SymmetricKey(data: material)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }()
}
