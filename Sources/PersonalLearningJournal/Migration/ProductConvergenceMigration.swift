import Foundation

public enum MigrationIssue: Equatable, Hashable, Sendable {
    case proofNeedsEvidence(UUID)
    case practiceNeedsProject(UUID)
    case projectNeedsSetup(UUID)
}

public struct MigrationDryRun: Equatable, Sendable {
    public var issues: [MigrationIssue]
    public init(issues: [MigrationIssue]) { self.issues = issues }
}

public enum ProofMigrationResolution: Equatable, Sendable {
    case keepNeedsEvidence
    case useArtifact(ProofArtifact)
}

public enum PracticeMigrationResolution: Equatable, Sendable {
    case keepUnlinked
    case linkToProject(UUID)
}

public enum MigrationResolution: Equatable, Sendable {
    case proof(UUID, ProofMigrationResolution)
    case practice(UUID, PracticeMigrationResolution)
}

public struct MigrationValidationReport: Equatable, Sendable {
    public var expectedEntityCount: Int
    public var storedEntityCount: Int
    public var validatedRelationshipCount: Int
    public var isValid: Bool

    public init(
        expectedEntityCount: Int,
        storedEntityCount: Int,
        validatedRelationshipCount: Int,
        isValid: Bool
    ) {
        self.expectedEntityCount = expectedEntityCount
        self.storedEntityCount = storedEntityCount
        self.validatedRelationshipCount = validatedRelationshipCount
        self.isValid = isValid
    }
}

public enum ProductConvergenceMigrationError: Error, Equatable, Sendable {
    case unresolvedIssues
    case invalidResolution
    case duplicateIdentifier
    case invalidRelationship
    case missingAttachment(String)
    case missingChecksum(UUID)
    case repositoryValidationFailed
}

public struct ProductConvergenceMigration {
    public static let identifier = "evidence-first-product-convergence-v1"

    private let now: () -> Date
    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    public func dryRun(snapshot: JournalSnapshot) -> MigrationDryRun {
        var issues: [MigrationIssue] = []
        issues += snapshot.proofs
            .filter { $0.deletedAt == nil && !$0.qualifies }
            .map { .proofNeedsEvidence($0.id) }

        issues += snapshot.practiceRoutines
            .filter { $0.projectId == nil && $0.deletedAt == nil }
            .map { .practiceNeedsProject($0.id) }

        issues += snapshot.projects
            .filter {
                $0.deletedAt == nil
                    && ($0.status == .active || $0.status == .lowFrequency)
                    && ($0.commitmentState != .needsSetup || $0.activeEvidenceContractId == nil)
            }
            .map { .projectNeedsSetup($0.id) }
        return MigrationDryRun(issues: issues.sorted(by: issueOrder))
    }

    public func execute(
        snapshot: JournalSnapshot,
        resolutions: [MigrationResolution],
        repository: any JournalRepository,
        backupDirectory: URL
    ) throws -> MigrationValidationReport {
        let report = dryRun(snapshot: snapshot)
        let proofResolutions = try proofResolutionMap(resolutions)
        let practiceResolutions = try practiceResolutionMap(resolutions)
        let requiredProofs: Set<UUID> = Set(report.issues.compactMap { issue -> UUID? in
            guard case let .proofNeedsEvidence(id) = issue else { return nil }
            return id
        })
        let requiredRoutines: Set<UUID> = Set(report.issues.compactMap { issue -> UUID? in
            guard case let .practiceNeedsProject(id) = issue else { return nil }
            return id
        })
        guard Set(proofResolutions.keys) == requiredProofs,
              Set(practiceResolutions.keys) == requiredRoutines else {
            throw ProductConvergenceMigrationError.unresolvedIssues
        }

        try writeBackup(snapshot: snapshot, to: backupDirectory)
        let migrated = try transformed(
            snapshot: snapshot,
            proofResolutions: proofResolutions,
            practiceResolutions: practiceResolutions
        )
        let validation = try validate(migrated)
        let targetEntities = entities(in: migrated)

        do {
            try repository.commit(
                JournalTransaction(
                    upserts: targetEntities,
                    origin: .migration,
                    stateMetadata: JournalStateMetadata(snapshot: migrated)
                )
            )
            let stored = try repository.snapshot()
            guard stored == migrated else {
                throw ProductConvergenceMigrationError.repositoryValidationFailed
            }
            try repository.commit(
                JournalTransaction(
                    origin: .migration,
                    completedMigrationIdentifier: Self.identifier
                )
            )
            return MigrationValidationReport(
                expectedEntityCount: validation.expectedEntityCount,
                storedEntityCount: entities(in: stored).count,
                validatedRelationshipCount: validation.validatedRelationshipCount,
                isValid: true
            )
        } catch {
            try? repository.commit(
                JournalTransaction(
                    upserts: entities(in: snapshot),
                    origin: .migration,
                    stateMetadata: JournalStateMetadata(snapshot: snapshot)
                )
            )
            throw error
        }
    }

    private func transformed(
        snapshot: JournalSnapshot,
        proofResolutions: [UUID: ProofMigrationResolution],
        practiceResolutions: [UUID: PracticeMigrationResolution]
    ) throws -> JournalSnapshot {
        var migrated = snapshot
        migrated.pendingFirstRecordProjectId = nil
        for index in migrated.projects.indices where
            migrated.projects[index].deletedAt == nil
                && (migrated.projects[index].status == .active || migrated.projects[index].status == .lowFrequency) {
            migrated.projects[index].commitmentState = .needsSetup
            migrated.projects[index].activeEvidenceContractId = nil
        }
        for index in migrated.proofs.indices {
            guard let resolution = proofResolutions[migrated.proofs[index].id] else { continue }
            switch resolution {
            case .keepNeedsEvidence:
                migrated.proofs[index].integrity = .needsEvidence
            case let .useArtifact(artifact):
                guard artifact.qualifies else {
                    throw ProductConvergenceMigrationError.invalidResolution
                }
                migrated.proofs[index].artifact = artifact
                migrated.proofs[index].integrity = .qualifying
                migrated.proofs[index].updatedAt = now()
            }
        }
        for index in migrated.practiceSessions.indices {
            guard let resolution = practiceResolutions[migrated.practiceSessions[index].routineId] else { continue }
            switch resolution {
            case .keepUnlinked:
                migrated.practiceSessions[index].linkedProjectId = nil
            case let .linkToProject(projectID):
                guard migrated.projects.contains(where: { $0.id == projectID && $0.deletedAt == nil }) else {
                    throw ProductConvergenceMigrationError.invalidResolution
                }
                migrated.practiceSessions[index].linkedProjectId = projectID
            }
            migrated.practiceSessions[index].updatedAt = now()
        }
        for index in migrated.practiceRoutines.indices {
            guard let resolution = practiceResolutions[migrated.practiceRoutines[index].id] else { continue }
            switch resolution {
            case .keepUnlinked:
                migrated.practiceRoutines[index].projectId = nil
                migrated.practiceRoutines[index].isArchived = true
            case let .linkToProject(projectID):
                migrated.practiceRoutines[index].projectId = projectID
            }
            migrated.practiceRoutines[index].updatedAt = now()
        }
        return migrated
    }

    private func validate(_ snapshot: JournalSnapshot) throws -> MigrationValidationReport {
        for ids in entityIDGroups(snapshot) where Set(ids).count != ids.count {
            throw ProductConvergenceMigrationError.duplicateIdentifier
        }
        let projectIDs = Set(snapshot.projects.filter { $0.deletedAt == nil }.map(\.id))
        let sessionIDs = Set(snapshot.sessions.filter { $0.deletedAt == nil }.map(\.id))
        let routineIDs = Set(snapshot.practiceRoutines.filter { $0.deletedAt == nil }.map(\.id))
        let proofIDs = Set(snapshot.proofs.filter { $0.deletedAt == nil }.map(\.id))
        let reviewIDs = Set(snapshot.reviews.filter { $0.deletedAt == nil }.map(\.id))
        let contractIDs = Set(snapshot.evidenceContracts.filter { $0.deletedAt == nil }.map(\.id))
        let planIDs = Set(snapshot.coursePlans.filter { $0.deletedAt == nil }.map(\.id))
        let phaseIDs = Set(snapshot.planPhases.filter { $0.deletedAt == nil }.map(\.id))
        var relationships = 0
        for session in snapshot.sessions where session.deletedAt == nil {
            guard projectIDs.contains(session.projectId) else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            relationships += 1
        }
        for proof in snapshot.proofs where proof.deletedAt == nil {
            guard projectIDs.contains(proof.projectId),
                  proof.sessionId.map(sessionIDs.contains) ?? true else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            if proof.qualifies,
               case let .attachment(path, _, _) = proof.artifact,
               !FileManager.default.fileExists(atPath: path) {
                throw ProductConvergenceMigrationError.missingAttachment(path)
            }
            relationships += 1 + (proof.sessionId == nil ? 0 : 1)
        }
        for session in snapshot.practiceSessions where session.deletedAt == nil {
            guard routineIDs.contains(session.routineId),
                  session.linkedProjectId.map(projectIDs.contains) ?? true else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            relationships += 1 + (session.linkedProjectId == nil ? 0 : 1)
        }
        for routine in snapshot.practiceRoutines where routine.deletedAt == nil && !routine.isArchived {
            guard let projectID = routine.projectId, projectIDs.contains(projectID) else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            relationships += 1
        }
        for contract in snapshot.evidenceContracts where contract.deletedAt == nil {
            guard projectIDs.contains(contract.projectId) else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            relationships += 1
        }
        for acceptance in snapshot.evidenceAcceptances where acceptance.deletedAt == nil {
            guard contractIDs.contains(acceptance.contractId), proofIDs.contains(acceptance.proofId) else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            relationships += 2
        }
        for revision in snapshot.proofRevisions where revision.deletedAt == nil {
            guard proofIDs.contains(revision.proofId) else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            guard !revision.artifactChecksum.trimmedForJournal.isEmpty else {
                throw ProductConvergenceMigrationError.missingChecksum(revision.id)
            }
            relationships += 1
        }
        for decision in snapshot.reviewDecisions where decision.deletedAt == nil {
            guard reviewIDs.contains(decision.reviewId), projectIDs.contains(decision.projectId),
                  decision.capstoneProofId.map(proofIDs.contains) ?? true else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            relationships += 2 + (decision.capstoneProofId == nil ? 0 : 1)
        }
        for event in snapshot.trailEvents where event.deletedAt == nil {
            guard projectIDs.contains(event.projectId) else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            relationships += 1
        }
        for plan in snapshot.coursePlans where plan.deletedAt == nil {
            guard projectIDs.contains(plan.projectId) else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            relationships += 1
        }
        for phase in snapshot.planPhases where phase.deletedAt == nil {
            guard planIDs.contains(phase.planId) else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            relationships += 1
        }
        for planned in snapshot.plannedSessions where planned.deletedAt == nil {
            guard planIDs.contains(planned.planId), phaseIDs.contains(planned.phaseId),
                  projectIDs.contains(planned.projectId) else {
                throw ProductConvergenceMigrationError.invalidRelationship
            }
            relationships += 3
        }
        return MigrationValidationReport(
            expectedEntityCount: entities(in: snapshot).count,
            storedEntityCount: 0,
            validatedRelationshipCount: relationships,
            isValid: true
        )
    }

    private func writeBackup(snapshot: JournalSnapshot, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try ExportService(now: now).exportJSON(snapshot: snapshot)
        try data.write(
            to: directory.appendingPathComponent("evidence-first-backup.json"),
            options: [.atomic]
        )
    }

    private func proofResolutionMap(
        _ resolutions: [MigrationResolution]
    ) throws -> [UUID: ProofMigrationResolution] {
        var values: [UUID: ProofMigrationResolution] = [:]
        for resolution in resolutions {
            guard case let .proof(id, value) = resolution else { continue }
            guard values.updateValue(value, forKey: id) == nil else {
                throw ProductConvergenceMigrationError.invalidResolution
            }
        }
        return values
    }

    private func practiceResolutionMap(
        _ resolutions: [MigrationResolution]
    ) throws -> [UUID: PracticeMigrationResolution] {
        var values: [UUID: PracticeMigrationResolution] = [:]
        for resolution in resolutions {
            guard case let .practice(id, value) = resolution else { continue }
            guard values.updateValue(value, forKey: id) == nil else {
                throw ProductConvergenceMigrationError.invalidResolution
            }
        }
        return values
    }

    private func entities(in snapshot: JournalSnapshot) -> [JournalEntity] {
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

    private func entityIDGroups(_ snapshot: JournalSnapshot) -> [[UUID]] {
        [snapshot.projects.map(\.id), snapshot.sessions.map(\.id), snapshot.proofs.map(\.id),
         snapshot.reviews.map(\.id), snapshot.evidenceContracts.map(\.id),
         snapshot.evidenceAcceptances.map(\.id), snapshot.proofRevisions.map(\.id),
         snapshot.reviewDecisions.map(\.id), snapshot.trailEvents.map(\.id),
         snapshot.coursePlans.map(\.id), snapshot.planPhases.map(\.id),
         snapshot.plannedSessions.map(\.id), snapshot.availabilityRules.map(\.id),
         snapshot.schedulingPreferences.map(\.id), snapshot.practiceRoutines.map(\.id),
         snapshot.practiceSessions.map(\.id)]
    }

    private func issueOrder(_ left: MigrationIssue, _ right: MigrationIssue) -> Bool {
        String(describing: left) < String(describing: right)
    }
}
