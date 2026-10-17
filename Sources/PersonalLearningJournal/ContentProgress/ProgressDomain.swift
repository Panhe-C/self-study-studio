import Foundation

/// Separate from the evidence-first Journal's `Project` and its persistence contract.
public enum ContentProgress {
    public static let schemaVersion = 1
    public static let maximumProjectNameScalars = 120
    public static let maximumUnitTitleScalars = 200
    public static let maximumUnits = 300
    /// Provisional local ceiling; P5 must validate it against real CloudKit records.
    public static let maximumEncodedBytes = 256 * 1024

    public struct LearningUnit: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var title: String
        public var order: Int
        public var isCompleted: Bool
        public var completedAt: Date?

        public init(id: UUID, title: String, order: Int, isCompleted: Bool = false, completedAt: Date? = nil) {
            self.id = id
            self.title = title
            self.order = order
            self.isCompleted = isCompleted
            self.completedAt = completedAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, order, isCompleted, completedAt
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(order, forKey: .order)
            try container.encode(isCompleted, forKey: .isCompleted)
            if let completedAt {
                try container.encode(completedAt, forKey: .completedAt)
            } else {
                try container.encodeNil(forKey: .completedAt)
            }
        }
    }

    public struct Project: Codable, Equatable, Identifiable, Sendable {
        public var schemaVersion: Int
        public var id: UUID
        public var name: String
        public var isPaused: Bool
        public var createdAt: Date
        public var updatedAt: Date
        public var units: [LearningUnit]

        public init(
            schemaVersion: Int = ContentProgress.schemaVersion,
            id: UUID,
            name: String,
            isPaused: Bool = false,
            createdAt: Date,
            updatedAt: Date,
            units: [LearningUnit] = []
        ) {
            self.schemaVersion = schemaVersion
            self.id = id
            self.name = name
            self.isPaused = isPaused
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.units = units
        }
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case unsupportedSchema
        case invalidName
        case invalidTitle
        case tooManyUnits
        case duplicateUnitID
        case invalidOrder
        case invalidCompletionTime
        case invalidTimestamps
        case oversizedProject
        case invalidShape
        case missingUnit
        case invalidReorder
        case pausedProject
    }

    public static func millisecondPrecision(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 * 1_000) / 1_000)
    }

    public static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func validate(_ project: Project) throws {
        guard project.schemaVersion == schemaVersion else { throw ValidationError.unsupportedSchema }
        let name = trimmed(project.name)
        guard !name.isEmpty, name == project.name,
              name.unicodeScalars.count <= maximumProjectNameScalars else {
            throw ValidationError.invalidName
        }
        guard project.units.count <= maximumUnits else { throw ValidationError.tooManyUnits }
        guard project.updatedAt >= project.createdAt else { throw ValidationError.invalidTimestamps }
        var ids = Set<UUID>()
        for (index, unit) in project.units.enumerated() {
            let title = trimmed(unit.title)
            guard !title.isEmpty, title == unit.title,
                  title.unicodeScalars.count <= maximumUnitTitleScalars else {
                throw ValidationError.invalidTitle
            }
            guard ids.insert(unit.id).inserted else { throw ValidationError.duplicateUnitID }
            guard unit.order == index else { throw ValidationError.invalidOrder }
            guard unit.isCompleted == (unit.completedAt != nil) else {
                throw ValidationError.invalidCompletionTime
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(JournalISO8601Codec.string(from: date))
        }
        let encoded = try encoder.encode(project)
        guard encoded.count <= maximumEncodedBytes else { throw ValidationError.oversizedProject }
    }

    public static func decode(_ data: Data) throws -> Project {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "id", "name", "isPaused", "createdAt", "updatedAt", "units"]),
              let units = object["units"] as? [[String: Any]],
              units.allSatisfy({ Set($0.keys) == Set(["id", "title", "order", "isCompleted", "completedAt"]) }) else {
            throw ValidationError.invalidShape
        }
        let project = try JSONDecoder.journal.decode(Project.self, from: data)
        try validate(project)
        return project
    }
}
