import Foundation
import SwiftData

public enum SwiftDataJournalRepositoryError: Error, Equatable, Sendable {
    case invalidStoredValue
}

public final class SwiftDataJournalRepository: JournalRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(container: ModelContainer, now: @escaping () -> Date = Date.init) {
        self.context = ModelContext(container)
        self.now = now
    }

    public convenience init(url: URL, now: @escaping () -> Date = Date.init) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(url: url)
        try self.init(container: Self.makeContainer(configuration), now: now)
    }

    public static func inMemory(
        now: @escaping () -> Date = Date.init
    ) throws -> SwiftDataJournalRepository {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try SwiftDataJournalRepository(
            container: makeContainer(configuration),
            now: now
        )
    }

    public func snapshot() throws -> JournalSnapshot {
        let metadata = try loadStateMetadata()
        return JournalSnapshot(
            projects: try decodedRecords(StoredProjectV2.self, as: Project.self),
            sessions: try decodedRecords(StoredSessionV2.self, as: LearningSession.self),
            proofs: try decodedRecords(StoredProofV2.self, as: Proof.self),
            reviews: try decodedRecords(StoredReviewV2.self, as: Review.self),
            trailEvents: try decodedRecords(StoredTrailEventV2.self, as: TrailEvent.self),
            coursePlans: try decodedRecords(StoredCoursePlanV2.self, as: CoursePlan.self),
            planPhases: try decodedRecords(StoredPlanPhaseV2.self, as: PlanPhase.self),
            plannedSessions: try decodedRecords(StoredPlannedSessionV2.self, as: PlannedSession.self),
            availabilityRules: try decodedRecords(StoredAvailabilityRuleV2.self, as: AvailabilityRule.self),
            schedulingPreferences: try decodedRecords(StoredSchedulingPreferencesV2.self, as: SchedulingPreferences.self),
            practiceRoutines: try decodedRecords(StoredPracticeRoutineV2.self, as: PracticeRoutine.self),
            practiceSessions: try decodedRecords(StoredPracticeSessionV2.self, as: PracticeSession.self),
            hasCompletedOnboarding: metadata?.hasCompletedOnboarding,
            pendingFirstRecordProjectId: metadata?.pendingFirstRecordProjectId
        )
    }

    public func commit(_ transaction: JournalTransaction) throws {
        do {
            for entity in transaction.upserts {
                try upsert(entity)
                if case .user = transaction.origin {
                    insertMutation(for: entity.reference, operation: .save)
                }
            }
            for reference in transaction.deletions {
                try markDeleted(reference)
                if case .user = transaction.origin {
                    insertMutation(for: reference, operation: .delete)
                }
            }
            if let metadata = transaction.stateMetadata {
                try storeRepositoryMetadata(
                    key: Self.stateMetadataKey,
                    value: JSONEncoder.journal.encode(metadata)
                )
            }
            if let identifier = transaction.completedMigrationIdentifier {
                try storeRepositoryMetadata(
                    key: Self.migrationKey(identifier),
                    value: Data("complete".utf8)
                )
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func pendingMutations(limit: Int) throws -> [PendingMutation] {
        let records = try context.fetch(FetchDescriptor<StoredPendingMutationV2>())
            .sorted { $0.enqueuedAt < $1.enqueuedAt }
        return try records.prefix(max(0, limit)).map { try $0.domain() }
    }

    public func acknowledge(
        _ mutationIDs: Set<UUID>,
        metadata: [SyncRecordMetadata]
    ) throws {
        do {
            let mutations = try context.fetch(FetchDescriptor<StoredPendingMutationV2>())
            for mutation in mutations where mutationIDs.contains(mutation.id) {
                context.delete(mutation)
            }

            let storedMetadata = try context.fetch(FetchDescriptor<StoredSyncMetadataV2>())
            for value in metadata {
                let key = Self.key(for: value.entity)
                let payload = try JSONEncoder.journal.encode(value)
                if let existing = storedMetadata.first(where: { $0.key == key }) {
                    existing.payload = payload
                } else {
                    context.insert(StoredSyncMetadataV2(key: key, payload: payload))
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func conflicts() throws -> [SyncConflict] {
        try context.fetch(FetchDescriptor<StoredSyncConflictV2>())
            .filter { $0.resolvedAt == nil }
            .map { try JSONDecoder.journal.decode(SyncConflict.self, from: $0.payload) }
    }

    public func resolveConflict(id: UUID, with entity: JournalEntity) throws {
        do {
            let conflicts = try context.fetch(FetchDescriptor<StoredSyncConflictV2>())
            guard let conflict = conflicts.first(where: { $0.id == id }) else { return }
            conflict.resolvedAt = now()
            var value = try JSONDecoder.journal.decode(SyncConflict.self, from: conflict.payload)
            value.resolvedAt = conflict.resolvedAt
            conflict.payload = try JSONEncoder.journal.encode(value)
            try upsert(entity)
            insertMutation(for: entity.reference, operation: .save)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func hasCompletedMigration(identifier: String) throws -> Bool {
        let key = Self.migrationKey(identifier)
        return try context.fetch(FetchDescriptor<StoredRepositoryMetadataV2>())
            .contains { $0.key == key }
    }

    public func entity(for reference: JournalEntityReference) throws -> JournalEntity? {
        switch reference.kind {
        case .project: return try entity(reference.id, in: StoredProjectV2.self, as: Project.self).map(JournalEntity.project)
        case .session: return try entity(reference.id, in: StoredSessionV2.self, as: LearningSession.self).map(JournalEntity.session)
        case .proof: return try entity(reference.id, in: StoredProofV2.self, as: Proof.self).map(JournalEntity.proof)
        case .review: return try entity(reference.id, in: StoredReviewV2.self, as: Review.self).map(JournalEntity.review)
        case .trailEvent: return try entity(reference.id, in: StoredTrailEventV2.self, as: TrailEvent.self).map(JournalEntity.trailEvent)
        case .coursePlan: return try entity(reference.id, in: StoredCoursePlanV2.self, as: CoursePlan.self).map(JournalEntity.coursePlan)
        case .planPhase: return try entity(reference.id, in: StoredPlanPhaseV2.self, as: PlanPhase.self).map(JournalEntity.planPhase)
        case .plannedSession: return try entity(reference.id, in: StoredPlannedSessionV2.self, as: PlannedSession.self).map(JournalEntity.plannedSession)
        case .availabilityRule: return try entity(reference.id, in: StoredAvailabilityRuleV2.self, as: AvailabilityRule.self).map(JournalEntity.availabilityRule)
        case .schedulingPreferences: return try entity(reference.id, in: StoredSchedulingPreferencesV2.self, as: SchedulingPreferences.self).map(JournalEntity.schedulingPreferences)
        case .practiceRoutine: return try entity(reference.id, in: StoredPracticeRoutineV2.self, as: PracticeRoutine.self).map(JournalEntity.practiceRoutine)
        case .practiceSession: return try entity(reference.id, in: StoredPracticeSessionV2.self, as: PracticeSession.self).map(JournalEntity.practiceSession)
        }
    }

    public func metadata(for reference: JournalEntityReference) throws -> SyncRecordMetadata? {
        let key = Self.key(for: reference)
        guard let record = try context.fetch(FetchDescriptor<StoredSyncMetadataV2>())
            .first(where: { $0.key == key }) else {
            return nil
        }
        return try JSONDecoder.journal.decode(SyncRecordMetadata.self, from: record.payload)
    }

    public func reference(recordName: String) throws -> JournalEntityReference? {
        for record in try context.fetch(FetchDescriptor<StoredSyncMetadataV2>()) {
            let metadata = try JSONDecoder.journal.decode(SyncRecordMetadata.self, from: record.payload)
            if metadata.recordName == recordName { return metadata.entity }
        }
        return nil
    }

    public func recordSyncFailures(
        retryable: [UUID: String],
        terminal: [UUID: String]
    ) throws {
        do {
            let records = try context.fetch(FetchDescriptor<StoredPendingMutationV2>())
            for record in records {
                if let message = retryable[record.id] {
                    record.retryCount += 1
                    record.lastError = message
                } else if let message = terminal[record.id] {
                    record.lastError = message
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func syncChangeToken() throws -> Data? {
        try context.fetch(FetchDescriptor<StoredRepositoryMetadataV2>())
            .first(where: { $0.key == Self.syncTokenKey })?.value
    }

    public func storeSyncChangeToken(_ token: Data?) throws {
        do {
            if let token {
                try storeRepositoryMetadata(key: Self.syncTokenKey, value: token)
            } else if let existing = try context.fetch(FetchDescriptor<StoredRepositoryMetadataV2>())
                .first(where: { $0.key == Self.syncTokenKey }) {
                context.delete(existing)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func applyRemote(
        _ transaction: JournalTransaction,
        conflicts: [SyncConflict]
    ) throws {
        do {
            for entity in transaction.upserts { try upsert(entity) }
            for reference in transaction.deletions { try markDeleted(reference) }
            for conflict in conflicts {
                context.insert(
                    StoredSyncConflictV2(
                        id: conflict.id,
                        payload: try JSONEncoder.journal.encode(conflict),
                        resolvedAt: conflict.resolvedAt
                    )
                )
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func saveCalendarBinding(_ binding: CalendarBinding) throws {
        do {
            let records = try context.fetch(FetchDescriptor<StoredCalendarBindingV2>())
            let payload = try JSONEncoder.journal.encode(binding)
            if let existing = records.first(where: { $0.plannedSessionID == binding.plannedSessionId }) {
                existing.payload = payload
            } else {
                context.insert(StoredCalendarBindingV2(plannedSessionID: binding.plannedSessionId, payload: payload))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func calendarBinding(for plannedSessionID: UUID) throws -> CalendarBinding? {
        guard let record = try context.fetch(FetchDescriptor<StoredCalendarBindingV2>())
            .first(where: { $0.plannedSessionID == plannedSessionID }) else {
            return nil
        }
        return try JSONDecoder.journal.decode(CalendarBinding.self, from: record.payload)
    }

    public func calendarBindings() throws -> [CalendarBinding] {
        try context.fetch(FetchDescriptor<StoredCalendarBindingV2>())
            .map { try JSONDecoder.journal.decode(CalendarBinding.self, from: $0.payload) }
            .sorted { $0.plannedSessionId.uuidString < $1.plannedSessionId.uuidString }
    }

    public func removeCalendarBinding(for plannedSessionID: UUID) throws {
        do {
            for record in try context.fetch(FetchDescriptor<StoredCalendarBindingV2>())
            where record.plannedSessionID == plannedSessionID {
                context.delete(record)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func targetCalendarIdentifier() throws -> String? {
        try context.fetch(FetchDescriptor<StoredCalendarSettingV2>())
            .first(where: { $0.key == Self.targetCalendarKey })?.value
    }

    public func saveTargetCalendarIdentifier(_ identifier: String?) throws {
        do {
            let records = try context.fetch(FetchDescriptor<StoredCalendarSettingV2>())
            if let existing = records.first(where: { $0.key == Self.targetCalendarKey }) {
                if let identifier {
                    existing.value = identifier
                } else {
                    context.delete(existing)
                }
            } else if let identifier {
                context.insert(StoredCalendarSettingV2(key: Self.targetCalendarKey, value: identifier))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func upsert(_ entity: JournalEntity) throws {
        switch entity {
        case let .project(value):
            try upsert(value, in: StoredProjectV2.self)
        case let .session(value):
            try upsert(value, in: StoredSessionV2.self)
        case let .proof(value):
            try upsert(value, in: StoredProofV2.self)
        case let .review(value):
            try upsert(value, in: StoredReviewV2.self)
        case let .trailEvent(value):
            try upsert(value, in: StoredTrailEventV2.self)
        case let .coursePlan(value):
            try upsert(value, in: StoredCoursePlanV2.self)
        case let .planPhase(value):
            try upsert(value, in: StoredPlanPhaseV2.self)
        case let .plannedSession(value):
            try upsert(value, in: StoredPlannedSessionV2.self)
        case let .availabilityRule(value):
            try upsert(value, in: StoredAvailabilityRuleV2.self)
        case let .schedulingPreferences(value):
            try upsert(value, in: StoredSchedulingPreferencesV2.self)
        case let .practiceRoutine(value):
            try upsert(value, in: StoredPracticeRoutineV2.self)
        case let .practiceSession(value):
            try upsert(value, in: StoredPracticeSessionV2.self)
        }
    }

    private func entity<Value: Codable, Record: StoredEntityV2>(
        _ id: UUID,
        in recordType: Record.Type,
        as valueType: Value.Type
    ) throws -> Value? {
        guard let record = try context.fetch(FetchDescriptor<Record>())
            .first(where: { $0.id == id }) else {
            return nil
        }
        return try JSONDecoder.journal.decode(Value.self, from: record.payload)
    }

    private func markDeleted(_ reference: JournalEntityReference) throws {
        switch reference.kind {
        case .project:
            try markDeleted(reference.id, in: StoredProjectV2.self, as: Project.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .session:
            try markDeleted(reference.id, in: StoredSessionV2.self, as: LearningSession.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .proof:
            try markDeleted(reference.id, in: StoredProofV2.self, as: Proof.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .review:
            try markDeleted(reference.id, in: StoredReviewV2.self, as: Review.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .trailEvent:
            try markDeleted(reference.id, in: StoredTrailEventV2.self, as: TrailEvent.self) {
                var value = $0
                value.deletedAt = now()
                return value
            }
        case .coursePlan:
            try markDeleted(reference.id, in: StoredCoursePlanV2.self, as: CoursePlan.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .planPhase:
            try markDeleted(reference.id, in: StoredPlanPhaseV2.self, as: PlanPhase.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .plannedSession:
            try markDeleted(reference.id, in: StoredPlannedSessionV2.self, as: PlannedSession.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .availabilityRule:
            try markDeleted(reference.id, in: StoredAvailabilityRuleV2.self, as: AvailabilityRule.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .schedulingPreferences:
            try markDeleted(reference.id, in: StoredSchedulingPreferencesV2.self, as: SchedulingPreferences.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .practiceRoutine:
            try markDeleted(reference.id, in: StoredPracticeRoutineV2.self, as: PracticeRoutine.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .practiceSession:
            try markDeleted(reference.id, in: StoredPracticeSessionV2.self, as: PracticeSession.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        }
    }

    private func upsert<Value: Codable & Identifiable, Record: StoredEntityV2>(
        _ value: Value,
        in recordType: Record.Type
    ) throws where Value.ID == UUID {
        let records = try context.fetch(FetchDescriptor<Record>())
        let payload = try JSONEncoder.journal.encode(value)
        let deletedAt = (value as? any DeletionDated)?.journalDeletedAt
        if let existing = records.first(where: { $0.id == value.id }) {
            existing.payload = payload
            existing.deletedAt = deletedAt
        } else {
            let ordinal = (records.map(\.ordinal).max() ?? -1) + 1
            context.insert(Record(id: value.id, ordinal: ordinal, payload: payload, deletedAt: deletedAt))
        }
    }

    private func markDeleted<Value: Codable, Record: StoredEntityV2>(
        _ id: UUID,
        in recordType: Record.Type,
        as valueType: Value.Type,
        transform: (Value) -> Value
    ) throws {
        let records = try context.fetch(FetchDescriptor<Record>())
        guard let record = records.first(where: { $0.id == id }) else { return }
        let value = try JSONDecoder.journal.decode(Value.self, from: record.payload)
        let deleted = transform(value)
        record.payload = try JSONEncoder.journal.encode(deleted)
        record.deletedAt = now()
    }

    private func decodedRecords<Record: StoredEntityV2, Value: Codable>(
        _ recordType: Record.Type,
        as valueType: Value.Type
    ) throws -> [Value] {
        try context.fetch(FetchDescriptor<Record>())
            .filter { $0.deletedAt == nil }
            .sorted { $0.ordinal < $1.ordinal }
            .map { try JSONDecoder.journal.decode(Value.self, from: $0.payload) }
    }

    private func insertMutation(
        for entity: JournalEntityReference,
        operation: SyncOperation
    ) {
        context.insert(
            StoredPendingMutationV2(
                id: UUID(),
                entityKindRaw: entity.kind.rawValue,
                entityID: entity.id,
                operationRaw: operation.rawValue,
                enqueuedAt: now(),
                retryCount: 0
            )
        )
    }

    private static func key(for reference: JournalEntityReference) -> String {
        "\(reference.kind.rawValue):\(reference.id.uuidString)"
    }

    private func loadStateMetadata() throws -> JournalStateMetadata? {
        guard let record = try context.fetch(FetchDescriptor<StoredRepositoryMetadataV2>())
            .first(where: { $0.key == Self.stateMetadataKey }) else {
            return nil
        }
        return try JSONDecoder.journal.decode(JournalStateMetadata.self, from: record.value)
    }

    private func storeRepositoryMetadata(key: String, value: Data) throws {
        let records = try context.fetch(FetchDescriptor<StoredRepositoryMetadataV2>())
        if let existing = records.first(where: { $0.key == key }) {
            existing.value = value
        } else {
            context.insert(StoredRepositoryMetadataV2(key: key, value: value))
        }
    }

    private static let stateMetadataKey = "journal-state"
    private static let syncTokenKey = "cloud-sync-token"
    private static let targetCalendarKey = "target-calendar"

    private static func migrationKey(_ identifier: String) -> String {
        "migration:\(identifier)"
    }

    private static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: StoredProjectV2.self,
            StoredSessionV2.self,
            StoredProofV2.self,
            StoredReviewV2.self,
            StoredTrailEventV2.self,
            StoredCoursePlanV2.self,
            StoredPlanPhaseV2.self,
            StoredPlannedSessionV2.self,
            StoredAvailabilityRuleV2.self,
            StoredSchedulingPreferencesV2.self,
            StoredPracticeRoutineV2.self,
            StoredPracticeSessionV2.self,
            StoredPendingMutationV2.self,
            StoredSyncMetadataV2.self,
            StoredSyncConflictV2.self,
            StoredRepositoryMetadataV2.self,
            StoredCalendarBindingV2.self,
            StoredCalendarSettingV2.self,
            configurations: configuration
        )
    }
}

public enum RepositoryFactory {
    public static func makeDefault(storeURL: URL) throws -> SwiftDataJournalRepository {
        try SwiftDataJournalRepository(url: storeURL)
    }
}

private protocol DeletionDated {
    var journalDeletedAt: Date? { get }
}

extension Project: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension LearningSession: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension Proof: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension Review: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension TrailEvent: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension CoursePlan: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension PlanPhase: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension PlannedSession: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension AvailabilityRule: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension SchedulingPreferences: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension PracticeRoutine: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension PracticeSession: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }

private protocol StoredEntityV2: PersistentModel {
    var id: UUID { get set }
    var ordinal: Int { get set }
    var payload: Data { get set }
    var deletedAt: Date? { get set }
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?)
}

@Model private final class StoredProjectV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredSessionV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredProofV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredReviewV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredTrailEventV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredCoursePlanV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredPlanPhaseV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredPlannedSessionV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredAvailabilityRuleV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredSchedulingPreferencesV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredPracticeRoutineV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredPracticeSessionV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredPendingMutationV2 {
    @Attribute(.unique) var id: UUID
    var entityKindRaw: String
    var entityID: UUID
    var operationRaw: String
    var enqueuedAt: Date
    var retryCount: Int
    var lastError: String?

    init(
        id: UUID,
        entityKindRaw: String,
        entityID: UUID,
        operationRaw: String,
        enqueuedAt: Date,
        retryCount: Int,
        lastError: String? = nil
    ) {
        self.id = id
        self.entityKindRaw = entityKindRaw
        self.entityID = entityID
        self.operationRaw = operationRaw
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
        self.lastError = lastError
    }

    func domain() throws -> PendingMutation {
        guard let kind = JournalEntityKind(rawValue: entityKindRaw),
              let operation = SyncOperation(rawValue: operationRaw) else {
            throw SwiftDataJournalRepositoryError.invalidStoredValue
        }
        return PendingMutation(
            id: id,
            entity: .init(kind, entityID),
            operation: operation,
            enqueuedAt: enqueuedAt,
            retryCount: retryCount,
            lastError: lastError
        )
    }
}

@Model private final class StoredSyncMetadataV2 {
    @Attribute(.unique) var key: String
    var payload: Data
    init(key: String, payload: Data) {
        self.key = key
        self.payload = payload
    }
}

@Model private final class StoredSyncConflictV2 {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var resolvedAt: Date?
    init(id: UUID, payload: Data, resolvedAt: Date?) {
        self.id = id
        self.payload = payload
        self.resolvedAt = resolvedAt
    }
}

@Model private final class StoredRepositoryMetadataV2 {
    @Attribute(.unique) var key: String
    var value: Data
    init(key: String, value: Data) {
        self.key = key
        self.value = value
    }
}

@Model private final class StoredCalendarBindingV2 {
    @Attribute(.unique) var plannedSessionID: UUID
    var payload: Data
    init(plannedSessionID: UUID, payload: Data) {
        self.plannedSessionID = plannedSessionID
        self.payload = payload
    }
}

@Model private final class StoredCalendarSettingV2 {
    @Attribute(.unique) var key: String
    var value: String
    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
