import Foundation

public enum PracticeSemanticColor: String, Codable, CaseIterable, Sendable {
    case coral, teal, yellow, blue, green, pink
}

public enum PracticeValidationError: Error, Equatable, Sendable {
    case missingProject
    case blankName
    case invalidTargetMinutes
    case invalidWeekdays
    case invalidReminderTime
    case invalidSessionTiming
}

public struct PracticeReminderTime: Codable, Equatable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

public struct PracticeRoutine: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID?
    public var name: String
    public var symbolName: String
    public var color: PracticeSemanticColor
    public var targetMinutes: Int
    public var weekdays: Set<Int>
    public var reminderTime: PracticeReminderTime?
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        projectId: UUID? = nil,
        name: String,
        symbolName: String,
        color: PracticeSemanticColor,
        targetMinutes: Int,
        weekdays: Set<Int>,
        reminderTime: PracticeReminderTime? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name.trimmedForJournal
        self.symbolName = symbolName.trimmedForJournal
        self.color = color
        self.targetMinutes = targetMinutes
        self.weekdays = weekdays
        self.reminderTime = reminderTime
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
    }

    public func validated(requireProject: Bool = true) throws -> PracticeRoutine {
        guard !requireProject || projectId != nil else {
            throw PracticeValidationError.missingProject
        }
        guard !name.trimmedForJournal.isEmpty else {
            throw PracticeValidationError.blankName
        }
        guard (1...1_440).contains(targetMinutes) else {
            throw PracticeValidationError.invalidTargetMinutes
        }
        guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else {
            throw PracticeValidationError.invalidWeekdays
        }
        if let reminderTime,
           !(0...23).contains(reminderTime.hour) || !(0...59).contains(reminderTime.minute) {
            throw PracticeValidationError.invalidReminderTime
        }

        var normalized = self
        normalized.name = name.trimmedForJournal
        normalized.symbolName = symbolName.trimmedForJournal
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, name, symbolName, color, targetMinutes, weekdays, reminderTime
        case isArchived, createdAt, updatedAt, deletedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            projectId: try container.decodeIfPresent(UUID.self, forKey: .projectId),
            name: try container.decode(String.self, forKey: .name),
            symbolName: try container.decode(String.self, forKey: .symbolName),
            color: try container.decode(PracticeSemanticColor.self, forKey: .color),
            targetMinutes: try container.decode(Int.self, forKey: .targetMinutes),
            weekdays: try container.decode(Set<Int>.self, forKey: .weekdays),
            reminderTime: try container.decodeIfPresent(PracticeReminderTime.self, forKey: .reminderTime),
            isArchived: try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            deletedAt: try container.decodeIfPresent(Date.self, forKey: .deletedAt),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        )
    }
}

public struct PracticeSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var routineId: UUID
    public var linkedProjectId: UUID?
    public var startedAt: Date
    public var endedAt: Date
    public var activeDurationSeconds: Int
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        routineId: UUID,
        linkedProjectId: UUID? = nil,
        startedAt: Date,
        endedAt: Date,
        activeDurationSeconds: Int,
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.routineId = routineId
        self.linkedProjectId = linkedProjectId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationSeconds = activeDurationSeconds
        self.note = note?.trimmedForJournal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
    }

    public func validated() throws -> PracticeSession {
        let wallClockDuration = endedAt.timeIntervalSince(startedAt)
        guard wallClockDuration >= 0,
              activeDurationSeconds >= 0,
              Double(activeDurationSeconds) <= wallClockDuration + 1 else {
            throw PracticeValidationError.invalidSessionTiming
        }

        var normalized = self
        normalized.note = note?.trimmedForJournal
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, routineId, linkedProjectId, startedAt, endedAt, activeDurationSeconds
        case note, createdAt, updatedAt, deletedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            routineId: try container.decode(UUID.self, forKey: .routineId),
            linkedProjectId: try container.decodeIfPresent(UUID.self, forKey: .linkedProjectId),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            endedAt: try container.decode(Date.self, forKey: .endedAt),
            activeDurationSeconds: try container.decode(Int.self, forKey: .activeDurationSeconds),
            note: try container.decodeIfPresent(String.self, forKey: .note),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            deletedAt: try container.decodeIfPresent(Date.self, forKey: .deletedAt),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        )
    }
}
