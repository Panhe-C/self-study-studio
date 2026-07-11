import CloudKit
import CryptoKit
import Foundation

public enum CloudRecordMapperError: Error, Equatable, Sendable {
    case unsupportedRecordType(String)
    case missingField(String)
    case invalidField(String)
    case mismatchedRecordIdentifier
}

public struct CloudRecordMapper {
    private let attachmentStore: AttachmentStore

    public init(attachmentStore: AttachmentStore = .defaultStore()) {
        self.attachmentStore = attachmentStore
    }

    public func record(
        for entity: JournalEntity,
        zoneID: CKRecordZone.ID
    ) throws -> CKRecord {
        let record = CKRecord(
            recordType: recordType(for: entity),
            recordID: CKRecord.ID(recordName: entity.reference.id.uuidString, zoneID: zoneID)
        )
        switch entity {
        case let .project(value): encode(value, into: record)
        case let .session(value): encode(value, into: record)
        case let .proof(value): try encode(value, into: record)
        case let .review(value): encode(value, into: record)
        case let .trailEvent(value): encode(value, into: record)
        }
        return record
    }

    public func entity(from record: CKRecord) throws -> JournalEntity {
        guard let id = UUID(uuidString: record.recordID.recordName) else {
            throw CloudRecordMapperError.mismatchedRecordIdentifier
        }
        switch record.recordType {
        case "Project": return .project(try decodeProject(record, id: id))
        case "LearningSession": return .session(try decodeSession(record, id: id))
        case "Proof": return .proof(try decodeProof(record, id: id))
        case "Review": return .review(try decodeReview(record, id: id))
        case "TrailEvent": return .trailEvent(try decodeTrailEvent(record, id: id))
        default: throw CloudRecordMapperError.unsupportedRecordType(record.recordType)
        }
    }

    public func importAsset(at temporaryURL: URL, proofID: UUID) throws -> URL {
        try attachmentStore.importCloudAsset(at: temporaryURL, proofId: proofID)
    }

    public func assetURL(from record: CKRecord) -> URL? {
        (record["asset"] as? CKAsset)?.fileURL
    }

    private func recordType(for entity: JournalEntity) -> String {
        switch entity {
        case .project: "Project"
        case .session: "LearningSession"
        case .proof: "Proof"
        case .review: "Review"
        case .trailEvent: "TrailEvent"
        }
    }

    private func encode(_ value: Project, into record: CKRecord) {
        record["name"] = value.name
        record["area"] = value.area
        record["goal"] = value.goal
        record["status"] = value.status.rawValue
        record["currentNextStep"] = value.currentNextStep
        record["lastActionType"] = value.lastActionType.rawValue
        record["defaultDurationMinutes"] = value.defaultDurationMinutes
        encodeDates(value.createdAt, value.updatedAt, value.archivedAt, value.deletedAt, value.schemaVersion, into: record)
    }

    private func encode(_ value: LearningSession, into record: CKRecord) {
        record["projectId"] = value.projectId.uuidString
        record["source"] = value.source.rawValue
        record["actionType"] = value.actionType.rawValue
        record["startedAt"] = value.startedAt
        record["endedAt"] = value.endedAt
        record["durationMinutes"] = value.durationMinutes
        record["note"] = value.note
        record["nextStepBefore"] = value.nextStepBefore
        record["nextStepAfter"] = value.nextStepAfter
        encodeDates(value.createdAt, value.updatedAt, nil, value.deletedAt, value.schemaVersion, into: record)
    }

    private func encode(_ value: Proof, into record: CKRecord) throws {
        record["projectId"] = value.projectId.uuidString
        record["sessionId"] = value.sessionId?.uuidString
        record["type"] = value.type.rawValue
        record["title"] = value.title
        record["statement"] = value.statement
        record["url"] = value.url?.absoluteString
        record["mimeType"] = value.mimeType
        record["fileSize"] = value.fileSize
        if let path = value.localPath {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CloudRecordMapperError.invalidField("localPath")
            }
            record["asset"] = CKAsset(fileURL: url)
            record["contentHash"] = try contentHash(of: url)
            let assetFileSize = try Data(contentsOf: url).count
            record["fileSize"] = assetFileSize
        }
        encodeDates(value.createdAt, value.updatedAt, nil, value.deletedAt, value.schemaVersion, into: record)
    }

    private func encode(_ value: Review, into record: CKRecord) {
        record["periodStart"] = value.periodStart
        record["periodEnd"] = value.periodEnd
        record["facts"] = value.facts as NSArray
        record["patterns"] = value.patterns as NSArray
        record["decisions"] = value.decisions as NSArray
        record["projectRecommendations"] = value.projectRecommendations
            .map { encodePair($0.key.uuidString, $0.value.rawValue) } as NSArray
        record["nextSteps"] = value.nextSteps
            .map { encodePair($0.key.uuidString, $0.value) } as NSArray
        record["aiSourceSummary"] = value.aiSourceSummary as NSArray
        record["sourceReferences"] = value.sourceReferences
            .flatMap { decision, sources in sources.map { encodePair(decision, $0) } } as NSArray
        encodeDates(value.createdAt, value.updatedAt, nil, value.deletedAt, value.schemaVersion, into: record)
    }

    private func encode(_ value: TrailEvent, into record: CKRecord) {
        record["projectId"] = value.projectId.uuidString
        record["type"] = value.type.rawValue
        record["sourceId"] = value.sourceId.uuidString
        record["occurredAt"] = value.occurredAt
        record["title"] = value.title
        record["detail"] = value.detail
        record["deletedAt"] = value.deletedAt
        record["schemaVersion"] = value.schemaVersion
    }

    private func encodeDates(
        _ createdAt: Date,
        _ updatedAt: Date,
        _ archivedAt: Date?,
        _ deletedAt: Date?,
        _ schemaVersion: Int,
        into record: CKRecord
    ) {
        record["createdAt"] = createdAt
        record["updatedAt"] = updatedAt
        record["archivedAt"] = archivedAt
        record["deletedAt"] = deletedAt
        record["schemaVersion"] = schemaVersion
    }

    private func decodeProject(_ record: CKRecord, id: UUID) throws -> Project {
        guard let status = ProjectStatus(rawValue: try string("status", from: record)),
              let actionType = ActionType(rawValue: try string("lastActionType", from: record)) else {
            throw CloudRecordMapperError.invalidField("project enum")
        }
        return Project(
            id: id,
            name: try string("name", from: record),
            area: try string("area", from: record),
            goal: try string("goal", from: record),
            status: status,
            currentNextStep: try string("currentNextStep", from: record),
            lastActionType: actionType,
            defaultDurationMinutes: try integer("defaultDurationMinutes", from: record),
            createdAt: try date("createdAt", from: record),
            updatedAt: try date("updatedAt", from: record),
            archivedAt: optionalDate("archivedAt", from: record),
            deletedAt: optionalDate("deletedAt", from: record),
            schemaVersion: try integer("schemaVersion", from: record)
        )
    }

    private func decodeSession(_ record: CKRecord, id: UUID) throws -> LearningSession {
        guard let source = SessionSource(rawValue: try string("source", from: record)),
              let action = ActionType(rawValue: try string("actionType", from: record)) else {
            throw CloudRecordMapperError.invalidField("session enum")
        }
        return try LearningSession(
            id: id,
            projectId: try uuid("projectId", from: record),
            source: source,
            actionType: action,
            startedAt: try date("startedAt", from: record),
            endedAt: try date("endedAt", from: record),
            durationMinutes: try integer("durationMinutes", from: record),
            note: try string("note", from: record),
            nextStepBefore: try string("nextStepBefore", from: record),
            nextStepAfter: try string("nextStepAfter", from: record),
            createdAt: try date("createdAt", from: record),
            updatedAt: try date("updatedAt", from: record),
            deletedAt: optionalDate("deletedAt", from: record),
            schemaVersion: try integer("schemaVersion", from: record)
        )
    }

    private func decodeProof(_ record: CKRecord, id: UUID) throws -> Proof {
        guard let type = ProofType(rawValue: try string("type", from: record)) else {
            throw CloudRecordMapperError.invalidField("proof type")
        }
        return try Proof(
            id: id,
            projectId: try uuid("projectId", from: record),
            sessionId: optionalUUID("sessionId", from: record),
            type: type,
            title: try string("title", from: record),
            statement: try string("statement", from: record),
            url: optionalString("url", from: record).flatMap(URL.init(string:)),
            mimeType: optionalString("mimeType", from: record),
            fileSize: optionalInteger("fileSize", from: record),
            createdAt: try date("createdAt", from: record),
            updatedAt: try date("updatedAt", from: record),
            deletedAt: optionalDate("deletedAt", from: record),
            schemaVersion: try integer("schemaVersion", from: record)
        )
    }

    private func decodeReview(_ record: CKRecord, id: UUID) throws -> Review {
        Review(
            id: id,
            periodStart: try date("periodStart", from: record),
            periodEnd: try date("periodEnd", from: record),
            facts: strings("facts", from: record),
            patterns: strings("patterns", from: record),
            decisions: strings("decisions", from: record),
            projectRecommendations: try statusDictionary(strings("projectRecommendations", from: record)),
            nextSteps: try stringDictionary(strings("nextSteps", from: record)),
            aiSourceSummary: strings("aiSourceSummary", from: record),
            sourceReferences: sourceReferences(strings("sourceReferences", from: record)),
            createdAt: try date("createdAt", from: record),
            updatedAt: try date("updatedAt", from: record),
            deletedAt: optionalDate("deletedAt", from: record),
            schemaVersion: try integer("schemaVersion", from: record)
        )
    }

    private func decodeTrailEvent(_ record: CKRecord, id: UUID) throws -> TrailEvent {
        guard let type = TrailEventType(rawValue: try string("type", from: record)) else {
            throw CloudRecordMapperError.invalidField("trail event type")
        }
        return TrailEvent(
            id: id,
            projectId: try uuid("projectId", from: record),
            type: type,
            sourceId: try uuid("sourceId", from: record),
            occurredAt: try date("occurredAt", from: record),
            title: try string("title", from: record),
            detail: try string("detail", from: record),
            deletedAt: optionalDate("deletedAt", from: record),
            schemaVersion: try integer("schemaVersion", from: record)
        )
    }

    private func contentHash(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func string(_ key: String, from record: CKRecord) throws -> String {
        guard let value = record[key] as? String else { throw CloudRecordMapperError.missingField(key) }
        return value
    }

    private func optionalString(_ key: String, from record: CKRecord) -> String? {
        record[key] as? String
    }

    private func integer(_ key: String, from record: CKRecord) throws -> Int {
        guard let value = record[key] as? NSNumber else { throw CloudRecordMapperError.missingField(key) }
        return value.intValue
    }

    private func optionalInteger(_ key: String, from record: CKRecord) -> Int? {
        (record[key] as? NSNumber)?.intValue
    }

    private func date(_ key: String, from record: CKRecord) throws -> Date {
        guard let value = record[key] as? Date else { throw CloudRecordMapperError.missingField(key) }
        return value
    }

    private func optionalDate(_ key: String, from record: CKRecord) -> Date? {
        record[key] as? Date
    }

    private func uuid(_ key: String, from record: CKRecord) throws -> UUID {
        guard let value = UUID(uuidString: optionalString(key, from: record) ?? "") else {
            throw CloudRecordMapperError.invalidField(key)
        }
        return value
    }

    private func optionalUUID(_ key: String, from record: CKRecord) -> UUID? {
        optionalString(key, from: record).flatMap(UUID.init(uuidString:))
    }

    private func strings(_ key: String, from record: CKRecord) -> [String] {
        record[key] as? [String] ?? []
    }

    private func statusDictionary(_ values: [String]) throws -> [UUID: ProjectStatus] {
        try Dictionary(uniqueKeysWithValues: values.map { value in
            let parts = try decodePair(value)
            guard let id = UUID(uuidString: parts.0), let status = ProjectStatus(rawValue: parts.1) else {
                throw CloudRecordMapperError.invalidField("projectRecommendations")
            }
            return (id, status)
        })
    }

    private func stringDictionary(_ values: [String]) throws -> [UUID: String] {
        try Dictionary(uniqueKeysWithValues: values.map { value in
            let parts = try decodePair(value)
            guard let id = UUID(uuidString: parts.0) else {
                throw CloudRecordMapperError.invalidField("nextSteps")
            }
            return (id, parts.1)
        })
    }

    private func sourceReferences(_ values: [String]) -> [String: [String]] {
        Dictionary(grouping: values.compactMap { try? decodePair($0) }, by: \.0)
            .mapValues { $0.map(\.1) }
    }

    private func encodePair(_ first: String, _ second: String) -> String {
        "\(Data(first.utf8).base64EncodedString()):\(Data(second.utf8).base64EncodedString())"
    }

    private func decodePair(_ value: String) throws -> (String, String) {
        let components = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2,
              let first = Data(base64Encoded: components[0]),
              let second = Data(base64Encoded: components[1]),
              let firstString = String(data: first, encoding: .utf8),
              let secondString = String(data: second, encoding: .utf8) else {
            throw CloudRecordMapperError.invalidField("relationship value")
        }
        return (firstString, secondString)
    }
}
