import Foundation

public enum PracticeBlocksMigrationIssue: Equatable, Hashable, Sendable {
    case multipleActiveRoutines(UUID, [UUID])
}

public struct PracticeBlocksMigrationDryRun: Equatable, Sendable {
    public let routineCount: Int
    public let blocklessRoutineCount: Int
    public let activeProjectCount: Int
    public let issues: [PracticeBlocksMigrationIssue]

    public init(
        routineCount: Int,
        blocklessRoutineCount: Int,
        activeProjectCount: Int,
        issues: [PracticeBlocksMigrationIssue] = []
    ) {
        self.routineCount = routineCount
        self.blocklessRoutineCount = blocklessRoutineCount
        self.activeProjectCount = activeProjectCount
        self.issues = issues
    }
}

public enum PracticeBlocksMigrationResolution: Equatable, Sendable {
    case merge(survivorID: UUID)
    case archive(survivorID: UUID)
}

public struct PracticeBlocksMigrationReport: Equatable, Sendable {
    public let expectedRoutineCount: Int
    public let storedRoutineCount: Int
    public let migratedCount: Int
    public let isValid: Bool

    public init(
        expectedRoutineCount: Int,
        storedRoutineCount: Int,
        migratedCount: Int,
        isValid: Bool
    ) {
        self.expectedRoutineCount = expectedRoutineCount
        self.storedRoutineCount = storedRoutineCount
        self.migratedCount = migratedCount
        self.isValid = isValid
    }
}

public enum PracticeBlocksMigrationError: Error, Equatable, Sendable {
    case multipleActiveRoutines(UUID)
    case invalidResolution
    case invalidRelationship
    case duplicateBlockIdentifier(UUID)
    case repositoryValidationFailed
}

/// Converts the original flat routine shape to ordered blocks and makes
/// multiple active routines an explicit, reversible migration decision.
public struct PracticeBlocksMigration {
    public static let identifier = "practice-blocks-v1"

    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func dryRun(snapshot: JournalSnapshot) -> PracticeBlocksMigrationDryRun {
        let activeGroups = Dictionary(grouping: operationalRoutines(in: snapshot), by: { $0.projectId ?? $0.id })
        let issues = activeGroups.compactMap { projectID, routines -> PracticeBlocksMigrationIssue? in
            guard routines.count > 1 else { return nil }
            return .multipleActiveRoutines(
                projectID,
                routines.map(\.id).sorted { $0.uuidString < $1.uuidString }
            )
        }
        .sorted { String(describing: $0) < String(describing: $1) }
        return PracticeBlocksMigrationDryRun(
            routineCount: snapshot.practiceRoutines.count,
            blocklessRoutineCount: snapshot.practiceRoutines.filter(\.blocks.isEmpty).count,
            activeProjectCount: activeGroups.count,
            issues: issues
        )
    }

    @discardableResult
    public func execute(
        snapshot: JournalSnapshot,
        repository: any JournalRepository,
        backupDirectory: URL,
        resolutions: [PracticeBlocksMigrationResolution] = []
    ) throws -> PracticeBlocksMigrationReport {
        let expectedCount = snapshot.practiceRoutines.count
        if try repository.hasCompletedMigration(identifier: Self.identifier) {
            let storedCount = (try? repository.snapshot().practiceRoutines.count) ?? expectedCount
            return PracticeBlocksMigrationReport(
                expectedRoutineCount: expectedCount,
                storedRoutineCount: storedCount,
                migratedCount: 0,
                isValid: storedCount == expectedCount
            )
        }

        let resolutionMap = try makeResolutionMap(
            snapshot: snapshot,
            resolutions: resolutions
        )
        for issue in dryRun(snapshot: snapshot).issues {
            guard case let .multipleActiveRoutines(projectID, _) = issue,
                  resolutionMap[projectID] != nil else {
                if case let .multipleActiveRoutines(projectID, _) = issue {
                    throw PracticeBlocksMigrationError.multipleActiveRoutines(projectID)
                }
                throw PracticeBlocksMigrationError.invalidResolution
            }
        }

        try writeBackup(snapshot: snapshot, to: backupDirectory)
        let migrated = try transformed(snapshot: snapshot, resolutions: resolutionMap)
        try validate(snapshot: migrated, expectedRoutineCount: expectedCount)

        do {
            try repository.commit(
                JournalTransaction(
                    upserts: changedRoutineEntities(from: snapshot, to: migrated),
                    origin: .user,
                    stateMetadata: JournalStateMetadata(snapshot: migrated),
                    completedMigrationIdentifier: Self.identifier
                )
            )
            let stored = try repository.snapshot()
            guard stored.practiceRoutines.count == expectedCount,
                  Set(stored.practiceRoutines.map(\.id)) == Set(migrated.practiceRoutines.map(\.id)) else {
                throw PracticeBlocksMigrationError.repositoryValidationFailed
            }
            let migratedCount = migrated.practiceRoutines.indices.reduce(into: 0) { count, index in
                if snapshot.practiceRoutines[index] != migrated.practiceRoutines[index] { count += 1 }
            }
            return PracticeBlocksMigrationReport(
                expectedRoutineCount: expectedCount,
                storedRoutineCount: stored.practiceRoutines.count,
                migratedCount: migratedCount,
                isValid: true
            )
        } catch {
            try? repository.commit(
                JournalTransaction(
                    upserts: changedRoutineEntities(from: migrated, to: snapshot),
                    origin: .migration,
                    stateMetadata: JournalStateMetadata(snapshot: snapshot),
                    removedMigrationIdentifier: Self.identifier
                )
            )
            throw error
        }
    }

    private func makeResolutionMap(
        snapshot: JournalSnapshot,
        resolutions: [PracticeBlocksMigrationResolution]
    ) throws -> [UUID: PracticeBlocksMigrationResolution] {
        var result: [UUID: PracticeBlocksMigrationResolution] = [:]
        let activeByProject = Dictionary(grouping: operationalRoutines(in: snapshot), by: { $0.projectId ?? $0.id })
        for resolution in resolutions {
            let survivorID: UUID
            switch resolution {
            case let .merge(id), let .archive(id): survivorID = id
            }
            guard let projectID = activeByProject.first(where: { _, routines in
                routines.contains { $0.id == survivorID }
            })?.key,
            result[projectID] == nil,
            activeByProject[projectID]?.count ?? 0 > 1 else {
                throw PracticeBlocksMigrationError.invalidResolution
            }
            result[projectID] = resolution
        }
        return result
    }

    private func transformed(
        snapshot: JournalSnapshot,
        resolutions: [UUID: PracticeBlocksMigrationResolution]
    ) throws -> JournalSnapshot {
        var migrated = snapshot
        for index in migrated.practiceRoutines.indices {
            if let value = migrated.practiceRoutines[index].migratedToBlocks() {
                migrated.practiceRoutines[index] = value
            }
            migrated.practiceRoutines[index].blocks = normalizedBlocks(
                migrated.practiceRoutines[index].blocks
            )
        }

        let operationalIDs = Set(operationalRoutines(in: migrated).map(\.id))
        let activeGroups = Dictionary(grouping: migrated.practiceRoutines.indices.filter {
            operationalIDs.contains(migrated.practiceRoutines[$0].id)
        }, by: { migrated.practiceRoutines[$0].projectId ?? migrated.practiceRoutines[$0].id })
        for (projectID, indexes) in activeGroups where indexes.count > 1 {
            guard let resolution = resolutions[projectID] else {
                throw PracticeBlocksMigrationError.multipleActiveRoutines(projectID)
            }
            let survivorID: UUID
            switch resolution {
            case let .merge(id), let .archive(id): survivorID = id
            }
            guard let survivorIndex = indexes.first(where: {
                migrated.practiceRoutines[$0].id == survivorID
            }) else { throw PracticeBlocksMigrationError.invalidResolution }

            switch resolution {
            case .merge:
                var merged = migrated.practiceRoutines[survivorIndex].orderedBlocks
                for index in indexes where index != survivorIndex {
                    merged += migrated.practiceRoutines[index].orderedBlocks
                    migrated.practiceRoutines[index].isArchived = true
                    migrated.practiceRoutines[index].updatedAt = max(
                        migrated.practiceRoutines[index].updatedAt,
                        now()
                    )
                }
                migrated.practiceRoutines[survivorIndex].blocks = normalizedBlocks(merged)
                migrated.practiceRoutines[survivorIndex].targetMinutes = merged.reduce(0) {
                    $0 + $1.targetMinutes
                }
            case .archive:
                for index in indexes where index != survivorIndex {
                    migrated.practiceRoutines[index].isArchived = true
                    migrated.practiceRoutines[index].updatedAt = max(
                        migrated.practiceRoutines[index].updatedAt,
                        now()
                    )
                }
            }
        }
        return migrated
    }

    private func normalizedBlocks(_ blocks: [PracticeBlock]) -> [PracticeBlock] {
        blocks.sorted {
            if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
            return $0.id.uuidString < $1.id.uuidString
        }.enumerated().map { index, block in
            var normalized = block
            normalized.ordinal = index
            return normalized
        }
    }

    private func validate(
        snapshot: JournalSnapshot,
        expectedRoutineCount: Int
    ) throws {
        guard snapshot.practiceRoutines.count == expectedRoutineCount else {
            throw PracticeBlocksMigrationError.repositoryValidationFailed
        }
        for routine in snapshot.practiceRoutines {
            guard !routine.blocks.isEmpty,
                  Set(routine.blocks.map(\.id)).count == routine.blocks.count,
                  routine.blocks.enumerated().allSatisfy({ $0.element.ordinal == $0.offset }) else {
                throw PracticeBlocksMigrationError.duplicateBlockIdentifier(routine.id)
            }
        }
        let activeByProject = Dictionary(grouping: operationalRoutines(in: snapshot), by: { $0.projectId ?? $0.id })
        guard activeByProject.values.allSatisfy({ $0.count <= 1 }) else {
            throw PracticeBlocksMigrationError.repositoryValidationFailed
        }
    }

    private func writeBackup(snapshot: JournalSnapshot, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("practice-blocks-v1-backup.json")
        try JSONEncoder.journal.encode(snapshot).write(to: url, options: [.atomic])
    }

    private func operationalRoutines(in snapshot: JournalSnapshot) -> [PracticeRoutine] {
        snapshot.operationalPracticeRoutines.filter { !$0.isArchived }
    }

    private func changedRoutineEntities(
        from original: JournalSnapshot,
        to migrated: JournalSnapshot
    ) -> [JournalEntity] {
        migrated.practiceRoutines.indices.compactMap { index in
            guard original.practiceRoutines.indices.contains(index),
                  original.practiceRoutines[index] != migrated.practiceRoutines[index] else {
                return nil
            }
            return .practiceRoutine(migrated.practiceRoutines[index])
        }
    }
}

public typealias PracticeRoutineBlocksMigration = PracticeBlocksMigration
