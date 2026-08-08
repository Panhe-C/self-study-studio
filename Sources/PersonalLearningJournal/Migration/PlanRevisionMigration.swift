import Foundation

/// Read-only migration preview for the B2 immutable learning-plan revision
/// metadata. Legacy records are never deleted or re-keyed.
public struct PlanRevisionMigrationDryRun: Equatable, Sendable {
    public let planCount: Int
    public let seriesCount: Int
    public let activeSeriesCount: Int
    public let issues: [PlanRevisionMigrationIssue]

    public init(
        planCount: Int,
        seriesCount: Int,
        activeSeriesCount: Int,
        issues: [PlanRevisionMigrationIssue] = []
    ) {
        self.planCount = planCount
        self.seriesCount = seriesCount
        self.activeSeriesCount = activeSeriesCount
        self.issues = issues
    }
}

public enum PlanRevisionMigrationIssue: Equatable, Hashable, Sendable {
    case multipleActivePlans(UUID)
}

public struct PlanRevisionMigrationReport: Equatable, Sendable {
    public let expectedPlanCount: Int
    public let storedPlanCount: Int
    public let migratedCount: Int
    public let isValid: Bool

    public init(
        expectedPlanCount: Int,
        storedPlanCount: Int,
        migratedCount: Int,
        isValid: Bool
    ) {
        self.expectedPlanCount = expectedPlanCount
        self.storedPlanCount = storedPlanCount
        self.migratedCount = migratedCount
        self.isValid = isValid
    }
}

public enum PlanRevisionMigrationError: Error, Equatable, Sendable {
    case invalidRelationship
    case duplicateRevisionIdentifier(UUID)
    case repositoryValidationFailed
    case multipleActivePlans(UUID)
}

public struct PlanRevisionMigration {
    public static let identifier = "learning-plan-revisions-v1"

    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func dryRun(snapshot: JournalSnapshot) -> PlanRevisionMigrationDryRun {
        let groups = seriesGroups(snapshot.coursePlans)
        let activeSeriesCount = groups.values.filter { plans in
            plans.contains(where: { $0.status == .active })
        }.count
        let issues = Dictionary(grouping: snapshot.coursePlans, by: \.projectId)
            .filter { $0.value.filter { $0.status == .active }.count > 1 }
            .map { PlanRevisionMigrationIssue.multipleActivePlans($0.key) }
            .sorted { String(describing: $0) < String(describing: $1) }
        return PlanRevisionMigrationDryRun(
            planCount: snapshot.coursePlans.count,
            seriesCount: groups.count,
            activeSeriesCount: activeSeriesCount,
            issues: issues
        )
    }

    @discardableResult
    public func execute(
        snapshot: JournalSnapshot,
        repository: any JournalRepository,
        backupDirectory: URL,
        activePlanSurvivors: [UUID: UUID] = [:]
    ) throws -> PlanRevisionMigrationReport {
        let expectedPlanCount = snapshot.coursePlans.count
        if try repository.hasCompletedMigration(identifier: Self.identifier) {
            let storedCount = (try? repository.snapshot().coursePlans.count) ?? expectedPlanCount
            return PlanRevisionMigrationReport(
                expectedPlanCount: expectedPlanCount,
                storedPlanCount: storedCount,
                migratedCount: 0,
                isValid: storedCount == expectedPlanCount
            )
        }

        for issue in dryRun(snapshot: snapshot).issues {
            switch issue {
            case let .multipleActivePlans(projectID):
                guard let survivorID = activePlanSurvivors[projectID],
                      snapshot.coursePlans.contains(where: {
                          $0.id == survivorID && $0.projectId == projectID && $0.status == .active
                      }) else {
                    // Ambiguous history must be resolved in the migration UI.
                    // Do not write a backup, marker, or inferred survivor.
                    throw PlanRevisionMigrationError.multipleActivePlans(projectID)
                }
            }
        }

        try writeBackup(snapshot: snapshot, to: backupDirectory)
        let migrated = try transformed(snapshot: snapshot, activePlanSurvivors: activePlanSurvivors)
        try validate(snapshot: migrated, expectedPlanCount: expectedPlanCount)

        let targetEntities = entities(in: migrated)
        do {
            try repository.commit(
                JournalTransaction(
                    upserts: targetEntities,
                    origin: .migration,
                    stateMetadata: JournalStateMetadata(snapshot: migrated),
                    completedMigrationIdentifier: Self.identifier
                )
            )
            let stored = try repository.snapshot()
            guard stored.coursePlans.count == expectedPlanCount,
                  Set(stored.coursePlans.map(\.id)) == Set(migrated.coursePlans.map(\.id)) else {
                throw PlanRevisionMigrationError.repositoryValidationFailed
            }
            return PlanRevisionMigrationReport(
                expectedPlanCount: expectedPlanCount,
                storedPlanCount: stored.coursePlans.count,
                migratedCount: migrated.coursePlans.filter { oldPlan in
                    snapshot.coursePlans.first(where: { $0.id == oldPlan.id }) != oldPlan
                }.count,
                isValid: true
            )
        } catch {
            // A failed activation/migration must leave the previous snapshot
            // recoverable. The backup remains on disk even when rollback fails.
            try? repository.commit(
                JournalTransaction(
                    upserts: entities(in: snapshot),
                    origin: .migration,
                    stateMetadata: JournalStateMetadata(snapshot: snapshot),
                    removedMigrationIdentifier: Self.identifier
                )
            )
            throw error
        }
    }

    private func transformed(
        snapshot: JournalSnapshot,
        activePlanSurvivors: [UUID: UUID]
    ) throws -> JournalSnapshot {
        var migrated = snapshot
        let groups = seriesGroups(snapshot.coursePlans)
        let planIDs = Set(snapshot.coursePlans.map(\.id))
        let projectIDs = Set(snapshot.projects.map(\.id))
        guard snapshot.coursePlans.allSatisfy({ projectIDs.contains($0.projectId) }) else {
            throw PlanRevisionMigrationError.invalidRelationship
        }

        var transformedPlans = snapshot.coursePlans
        var activePlanByProject: [UUID: UUID] = [:]
        for (_, plans) in groups {
            let sorted = plans.sorted(by: revisionOrder)
            guard let first = sorted.first else { continue }
            let seriesID = sorted.first(where: { $0.planSeriesID != $0.id })?.planSeriesID ?? first.id
            let activeCandidates = sorted.filter { $0.status == .active }
            let hasExplicitProjectSurvivor = activePlanSurvivors[first.projectId] != nil
            let activeWinner: LearningPlan?
            if let survivorID = activePlanSurvivors[first.projectId] {
                activeWinner = activeCandidates.first { $0.id == survivorID }
            } else {
                activeWinner = activeCandidates.max(by: revisionOrder)
            }
            if let activeWinner {
                activePlanByProject[activeWinner.projectId] = activeWinner.id
            }
            var previousRevisionID: UUID?
            for plan in sorted {
                guard let index = transformedPlans.firstIndex(where: { $0.id == plan.id }) else {
                    throw PlanRevisionMigrationError.invalidRelationship
                }
                var value = transformedPlans[index]
                value.planSeriesID = seriesID
                value.revisionID = plan.id
                value.baseRevisionID = previousRevisionID
                value.supersedesID = previousRevisionID
                let shouldArchiveActive = value.status == .active && (
                    activeWinner.map { value.id != $0.id } ?? hasExplicitProjectSurvivor
                )
                if shouldArchiveActive {
                    value.status = .archived
                    // Preserve legacy timestamps for metadata-only changes. A
                    // status transition is the one case where the migration
                    // itself should be visible in the record history.
                    value.updatedAt = max(value.updatedAt, now())
                }
                transformedPlans[index] = value
                previousRevisionID = value.revisionID
            }
        }
        guard Set(transformedPlans.map(\.id)) == planIDs else {
            throw PlanRevisionMigrationError.invalidRelationship
        }
        migrated.coursePlans = transformedPlans
        for index in migrated.planPhases.indices {
            guard let plan = transformedPlans.first(where: { $0.id == migrated.planPhases[index].planId }) else {
                throw PlanRevisionMigrationError.invalidRelationship
            }
            migrated.planPhases[index].planRevisionID = plan.revisionID
            migrated.planPhases[index].planSeriesID = plan.planSeriesID
            migrated.planPhases[index].isStructuralLocked = plan.isPublished
        }
        for index in migrated.plannedSessions.indices {
            guard let plan = transformedPlans.first(where: { $0.id == migrated.plannedSessions[index].planId }) else {
                throw PlanRevisionMigrationError.invalidRelationship
            }
            migrated.plannedSessions[index].planRevisionID = plan.revisionID
            migrated.plannedSessions[index].planSeriesID = plan.planSeriesID
            migrated.plannedSessions[index].isStructuralLocked = plan.isPublished
        }
        let activePlansByProject = Dictionary(
            uniqueKeysWithValues: transformedPlans
                .filter { $0.status == .active }
                .map { ($0.projectId, $0) }
        )
        for index in migrated.practiceRoutines.indices {
            var routine = migrated.practiceRoutines[index]
            if let revisionID = routine.planRevisionID,
               let plan = transformedPlans.first(where: { $0.revisionID == revisionID }) {
                routine.planRevisionID = plan.revisionID
                routine.planSeriesID = plan.planSeriesID
                routine.isStructuralLocked = plan.isPublished
            } else if let projectID = routine.projectId,
                      let activePlan = activePlansByProject[projectID] {
                // Legacy routines were project-owned. Bind them to the
                // surviving active revision without duplicating or deleting
                // their record; future structural edits can now be revisioned.
                routine.planRevisionID = activePlan.revisionID
                routine.planSeriesID = activePlan.planSeriesID
                routine.isStructuralLocked = activePlan.isPublished
            }
            migrated.practiceRoutines[index] = routine
        }
        for index in migrated.projects.indices {
            let projectID = migrated.projects[index].id
            migrated.projects[index].activeCoursePlanId = activePlanByProject[projectID]
        }
        return migrated
    }

    private func validate(snapshot: JournalSnapshot, expectedPlanCount: Int) throws {
        guard snapshot.coursePlans.count == expectedPlanCount else {
            throw PlanRevisionMigrationError.repositoryValidationFailed
        }
        let revisions = snapshot.coursePlans.map(\.revisionID)
        guard Set(revisions).count == revisions.count else {
            throw PlanRevisionMigrationError.duplicateRevisionIdentifier(revisions.first ?? UUID())
        }
        let projectIDs = Set(snapshot.projects.map(\.id))
        guard snapshot.coursePlans.allSatisfy({ projectIDs.contains($0.projectId) }) else {
            throw PlanRevisionMigrationError.invalidRelationship
        }
        for plans in seriesGroups(snapshot.coursePlans).values {
            let activeCount = plans.filter { $0.status == .active }.count
            guard activeCount <= 1 else {
                throw PlanRevisionMigrationError.repositoryValidationFailed
            }
        }
        for plans in Dictionary(grouping: snapshot.coursePlans, by: \.projectId).values {
            let activeCount = plans.filter { $0.status == .active }.count
            guard activeCount <= 1 else {
                throw PlanRevisionMigrationError.repositoryValidationFailed
            }
        }
    }

    private func seriesGroups(_ plans: [LearningPlan]) -> [String: [LearningPlan]] {
        let byProject = Dictionary(grouping: plans, by: \.projectId)
        var result: [String: [LearningPlan]] = [:]
        for (projectID, projectPlans) in byProject {
            let explicit = projectPlans.contains { $0.planSeriesID != $0.id }
            if !explicit {
                result["legacy:\(projectID.uuidString)"] = projectPlans
            } else {
                for (seriesID, values) in Dictionary(grouping: projectPlans, by: \.planSeriesID) {
                    result["series:\(seriesID.uuidString)"] = values
                }
            }
        }
        return result
    }

    private func revisionOrder(_ lhs: LearningPlan, _ rhs: LearningPlan) -> Bool {
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func writeBackup(snapshot: JournalSnapshot, to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("learning-plan-revisions-v1-backup.json")
        try JSONEncoder.journal.encode(snapshot).write(to: url, options: [.atomic])
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
}

/// More descriptive public spelling for callers that use the product name.
public typealias LearningPlanRevisionMigration = PlanRevisionMigration
public typealias LearningPlanRevisionMigrationDryRun = PlanRevisionMigrationDryRun
public typealias LearningPlanRevisionMigrationReport = PlanRevisionMigrationReport
