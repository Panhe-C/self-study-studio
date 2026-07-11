import Foundation

public enum SyncMergeError: Error, Equatable, Sendable {
    case mismatchedEntityReferences
    case invalidEntityPayload
}

public enum SyncMergeResult: Equatable, Sendable {
    case merged(JournalEntity)
    case conflict(SyncConflict)
}

public struct SyncMergeService {
    public init() {}

    public func merge(
        base: JournalEntity,
        local: JournalEntity,
        server: JournalEntity,
        now: Date = Date()
    ) throws -> SyncMergeResult {
        guard base.reference == local.reference,
              base.reference == server.reference else {
            throw SyncMergeError.mismatchedEntityReferences
        }

        switch (base, local, server) {
        case let (.project(base), .project(local), .project(server)):
            return try merge(base: base, local: local, server: server, wrap: JournalEntity.project, now: now)
        case let (.session(base), .session(local), .session(server)):
            return try merge(base: base, local: local, server: server, wrap: JournalEntity.session, now: now)
        case let (.proof(base), .proof(local), .proof(server)):
            return try merge(base: base, local: local, server: server, wrap: JournalEntity.proof, now: now)
        case let (.review(base), .review(local), .review(server)):
            return try merge(base: base, local: local, server: server, wrap: JournalEntity.review, now: now)
        case let (.trailEvent(base), .trailEvent(local), .trailEvent(server)):
            return try merge(base: base, local: local, server: server, wrap: JournalEntity.trailEvent, now: now)
        case let (.coursePlan(base), .coursePlan(local), .coursePlan(server)):
            return try merge(base: base, local: local, server: server, wrap: JournalEntity.coursePlan, now: now)
        case let (.planPhase(base), .planPhase(local), .planPhase(server)):
            return try merge(base: base, local: local, server: server, wrap: JournalEntity.planPhase, now: now)
        case let (.plannedSession(base), .plannedSession(local), .plannedSession(server)):
            return try merge(base: base, local: local, server: server, wrap: JournalEntity.plannedSession, now: now)
        default:
            throw SyncMergeError.mismatchedEntityReferences
        }
    }

    private func merge<Value: Codable & Equatable>(
        base: Value,
        local: Value,
        server: Value,
        wrap: (Value) -> JournalEntity,
        now: Date
    ) throws -> SyncMergeResult {
        let baseFields = try fields(for: base)
        let localFields = try fields(for: local)
        let serverFields = try fields(for: server)
        var mergedFields: [String: Any] = [:]
        var conflicts: [String] = []
        let allKeys = Set(baseFields.keys)
            .union(localFields.keys)
            .union(serverFields.keys)
        for key in allKeys.sorted() {
            let baseValue = baseFields[key] ?? NSNull()
            let localValue = localFields[key] ?? NSNull()
            let serverValue = serverFields[key] ?? NSNull()

            if key == "updatedAt" {
                mergedFields[key] = latestDateString(localValue, serverValue)
            } else if valuesEqual(localValue, baseValue) {
                mergedFields[key] = serverValue
            } else if valuesEqual(serverValue, baseValue) || valuesEqual(localValue, serverValue) {
                mergedFields[key] = localValue
            } else {
                conflicts.append(key)
                mergedFields[key] = baseValue
            }
        }

        let baseEntity = wrap(base)
        let localEntity = wrap(local)
        let serverEntity = wrap(server)
        let proposedData = try JSONSerialization.data(withJSONObject: mergedFields, options: [.sortedKeys])
        if !conflicts.isEmpty {
            return .conflict(
                SyncConflict(
                    entity: baseEntity.reference,
                    basePayload: try JSONEncoder.journal.encode(baseEntity),
                    localPayload: try JSONEncoder.journal.encode(localEntity),
                    serverPayload: try JSONEncoder.journal.encode(serverEntity),
                    proposedPayload: proposedData,
                    conflictingFields: conflicts,
                    createdAt: now
                )
            )
        }

        let merged = try JSONDecoder.journal.decode(Value.self, from: proposedData)
        return .merged(wrap(merged))
    }

    private func fields<Value: Encodable>(for value: Value) throws -> [String: Any] {
        guard let fields = try JSONSerialization.jsonObject(
            with: JSONEncoder.journal.encode(value)
        ) as? [String: Any] else {
            throw SyncMergeError.invalidEntityPayload
        }
        return fields
    }

    private func valuesEqual(_ left: Any, _ right: Any) -> Bool {
        (left as AnyObject).isEqual(right)
    }

    private func latestDateString(_ left: Any, _ right: Any) -> Any {
        guard let left = left as? String,
              let right = right as? String else {
            return left
        }
        return left >= right ? left : right
    }
}
