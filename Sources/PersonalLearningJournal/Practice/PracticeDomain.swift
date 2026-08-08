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

/// An ordered, soft-targeted part of a composite practice routine. Block
/// targets guide the session but never make a block mandatory or complete.
public struct PracticeBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var targetMinutes: Int
    public var ordinal: Int
    public var focus: String?
    public var nextFocusCandidates: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        targetMinutes: Int,
        ordinal: Int,
        focus: String? = nil,
        nextFocusCandidates: [String] = []
    ) {
        self.id = id
        self.name = name.trimmedForJournal
        self.targetMinutes = targetMinutes
        self.ordinal = ordinal
        self.focus = focus.map { $0.trimmedForJournal }.flatMap { $0.isEmpty ? nil : $0 }
        self.nextFocusCandidates = nextFocusCandidates
            .map { $0.trimmedForJournal }
            .filter { !$0.isEmpty }
    }

    public var currentFocus: String? {
        get { focus }
        set { focus = newValue.map { $0.trimmedForJournal }.flatMap { $0.isEmpty ? nil : $0 } }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, targetMinutes, ordinal, focus, nextFocusCandidates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            targetMinutes: try container.decode(Int.self, forKey: .targetMinutes),
            ordinal: try container.decode(Int.self, forKey: .ordinal),
            focus: try container.decodeIfPresent(String.self, forKey: .focus),
            nextFocusCandidates: try container.decodeIfPresent([String].self, forKey: .nextFocusCandidates) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(targetMinutes, forKey: .targetMinutes)
        try container.encode(ordinal, forKey: .ordinal)
        try container.encodeIfPresent(focus, forKey: .focus)
        if !nextFocusCandidates.isEmpty {
            try container.encode(nextFocusCandidates, forKey: .nextFocusCandidates)
        }
    }

    public func validated() throws -> PracticeBlock {
        guard !name.trimmedForJournal.isEmpty else {
            throw PracticeValidationError.blankName
        }
        guard (1...1_440).contains(targetMinutes) else {
            throw PracticeValidationError.invalidTargetMinutes
        }
        guard ordinal >= 0 else {
            throw PracticeValidationError.invalidTargetMinutes
        }
        var normalized = self
        normalized.name = name.trimmedForJournal
        normalized.focus = focus.map { $0.trimmedForJournal }.flatMap { $0.isEmpty ? nil : $0 }
        normalized.nextFocusCandidates = nextFocusCandidates
            .map { $0.trimmedForJournal }
            .filter { !$0.isEmpty }
        return normalized
    }
}

/// One active interval attributed to a routine block. Pauses are represented
/// explicitly when imported from a player, but never contribute to a summary.
public struct PracticeSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var blockID: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var activeDurationSeconds: Int
    public var isPause: Bool
    /// Immutable context captured when the segment was observed. Keeping
    /// this beside the relationship ID means later routine-draft edits cannot
    /// rewrite the learner's historical session.
    public var observedBlockName: String?
    public var observedFocus: String?
    public var observedNextFocusCandidates: [String]

    public init(
        id: UUID = UUID(),
        blockID: UUID,
        startedAt: Date,
        endedAt: Date,
        activeDurationSeconds: Int,
        isPause: Bool = false,
        observedBlockName: String? = nil,
        observedFocus: String? = nil,
        observedNextFocusCandidates: [String] = []
    ) {
        self.id = id
        self.blockID = blockID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationSeconds = activeDurationSeconds
        self.isPause = isPause
        self.observedBlockName = observedBlockName.map { $0.trimmedForJournal }.flatMap { $0.isEmpty ? nil : $0 }
        self.observedFocus = observedFocus.map { $0.trimmedForJournal }.flatMap { $0.isEmpty ? nil : $0 }
        self.observedNextFocusCandidates = observedNextFocusCandidates
            .map { $0.trimmedForJournal }
            .filter { !$0.isEmpty }
    }

    public init(
        block: PracticeBlock,
        startedAt: Date,
        endedAt: Date,
        activeDurationSeconds: Int,
        isPause: Bool = false
    ) {
        self.init(
            blockID: block.id,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: activeDurationSeconds,
            isPause: isPause,
            observedBlockName: block.name,
            observedFocus: block.focus,
            observedNextFocusCandidates: block.nextFocusCandidates
        )
    }

    public func validated() throws -> PracticeSegment {
        guard endedAt >= startedAt,
              activeDurationSeconds >= 0,
              Double(activeDurationSeconds) <= endedAt.timeIntervalSince(startedAt) + 1,
              !isPause || activeDurationSeconds == 0 else {
            throw PracticeValidationError.invalidSessionTiming
        }
        var normalized = self
        normalized.observedBlockName = observedBlockName.map { $0.trimmedForJournal }.flatMap { $0.isEmpty ? nil : $0 }
        normalized.observedFocus = observedFocus.map { $0.trimmedForJournal }.flatMap { $0.isEmpty ? nil : $0 }
        normalized.observedNextFocusCandidates = observedNextFocusCandidates
            .map { $0.trimmedForJournal }
            .filter { !$0.isEmpty }
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, blockID, startedAt, endedAt, activeDurationSeconds, isPause
        case observedBlockName, observedFocus, observedNextFocusCandidates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            blockID: try container.decode(UUID.self, forKey: .blockID),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            endedAt: try container.decode(Date.self, forKey: .endedAt),
            activeDurationSeconds: try container.decode(Int.self, forKey: .activeDurationSeconds),
            isPause: try container.decodeIfPresent(Bool.self, forKey: .isPause) ?? false,
            observedBlockName: try container.decodeIfPresent(String.self, forKey: .observedBlockName),
            observedFocus: try container.decodeIfPresent(String.self, forKey: .observedFocus),
            observedNextFocusCandidates: try container.decodeIfPresent([String].self, forKey: .observedNextFocusCandidates) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(blockID, forKey: .blockID)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(activeDurationSeconds, forKey: .activeDurationSeconds)
        try container.encode(isPause, forKey: .isPause)
        try container.encodeIfPresent(observedBlockName, forKey: .observedBlockName)
        try container.encodeIfPresent(observedFocus, forKey: .observedFocus)
        if !observedNextFocusCandidates.isEmpty {
            try container.encode(observedNextFocusCandidates, forKey: .observedNextFocusCandidates)
        }
    }
}

public struct PracticeBlockSummary: Codable, Equatable, Sendable {
    public let blockID: UUID
    public let targetMinutes: Int
    public let activeDurationSeconds: Int
    public let visitCount: Int
    public let wasSkipped: Bool
    public let wasExtended: Bool
    public let observedBlockName: String?
    public let observedFocus: String?
    public let observedNextFocusCandidates: [String]

    public init(
        blockID: UUID,
        targetMinutes: Int,
        activeDurationSeconds: Int,
        visitCount: Int,
        wasSkipped: Bool,
        wasExtended: Bool,
        observedBlockName: String? = nil,
        observedFocus: String? = nil,
        observedNextFocusCandidates: [String] = []
    ) {
        self.blockID = blockID
        self.targetMinutes = targetMinutes
        self.activeDurationSeconds = activeDurationSeconds
        self.visitCount = visitCount
        self.wasSkipped = wasSkipped
        self.wasExtended = wasExtended
        self.observedBlockName = observedBlockName.map { $0.trimmedForJournal }.flatMap { $0.isEmpty ? nil : $0 }
        self.observedFocus = observedFocus.map { $0.trimmedForJournal }.flatMap { $0.isEmpty ? nil : $0 }
        self.observedNextFocusCandidates = observedNextFocusCandidates
            .map { $0.trimmedForJournal }
            .filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case blockID, targetMinutes, activeDurationSeconds, visitCount, wasSkipped, wasExtended
        case observedBlockName, observedFocus, observedNextFocusCandidates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            blockID: try container.decode(UUID.self, forKey: .blockID),
            targetMinutes: try container.decode(Int.self, forKey: .targetMinutes),
            activeDurationSeconds: try container.decode(Int.self, forKey: .activeDurationSeconds),
            visitCount: try container.decode(Int.self, forKey: .visitCount),
            wasSkipped: try container.decode(Bool.self, forKey: .wasSkipped),
            wasExtended: try container.decode(Bool.self, forKey: .wasExtended),
            observedBlockName: try container.decodeIfPresent(String.self, forKey: .observedBlockName),
            observedFocus: try container.decodeIfPresent(String.self, forKey: .observedFocus),
            observedNextFocusCandidates: try container.decodeIfPresent([String].self, forKey: .observedNextFocusCandidates) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blockID, forKey: .blockID)
        try container.encode(targetMinutes, forKey: .targetMinutes)
        try container.encode(activeDurationSeconds, forKey: .activeDurationSeconds)
        try container.encode(visitCount, forKey: .visitCount)
        try container.encode(wasSkipped, forKey: .wasSkipped)
        try container.encode(wasExtended, forKey: .wasExtended)
        try container.encodeIfPresent(observedBlockName, forKey: .observedBlockName)
        try container.encodeIfPresent(observedFocus, forKey: .observedFocus)
        if !observedNextFocusCandidates.isEmpty {
            try container.encode(observedNextFocusCandidates, forKey: .observedNextFocusCandidates)
        }
    }
}

public struct PracticeSummary: Codable, Equatable, Sendable {
    public let totalActiveDurationSeconds: Int
    public let blockSummaries: [PracticeBlockSummary]
    public let attentionMarker: String?

    public init(
        totalActiveDurationSeconds: Int,
        blockSummaries: [PracticeBlockSummary],
        attentionMarker: String? = nil
    ) {
        self.totalActiveDurationSeconds = totalActiveDurationSeconds
        self.blockSummaries = blockSummaries
        self.attentionMarker = attentionMarker.map { $0.trimmedForJournal }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func from(
        blocks: [PracticeBlock],
        segments: [PracticeSegment],
        attentionMarker: String?
    ) -> PracticeSummary {
        var durations: [UUID: Int] = [:]
        var visits: [UUID: Int] = [:]
        for segment in segments where !segment.isPause && segment.activeDurationSeconds > 0 {
            durations[segment.blockID, default: 0] += segment.activeDurationSeconds
            visits[segment.blockID, default: 0] += 1
        }

        let orderedBlocks = blocks.sorted {
            if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
            return $0.id.uuidString < $1.id.uuidString
        }
        let blockSummaries = orderedBlocks.map { block in
            let active = durations[block.id, default: 0]
            let targetSeconds = block.targetMinutes * 60
            return PracticeBlockSummary(
                blockID: block.id,
                targetMinutes: block.targetMinutes,
                activeDurationSeconds: active,
                visitCount: visits[block.id, default: 0],
                wasSkipped: active == 0,
                wasExtended: active > targetSeconds,
                observedBlockName: block.name,
                observedFocus: block.focus,
                observedNextFocusCandidates: block.nextFocusCandidates
            )
        }
        return PracticeSummary(
            totalActiveDurationSeconds: durations.values.reduce(0, +),
            blockSummaries: blockSummaries,
            attentionMarker: attentionMarker
        )
    }
}

public struct PracticeRoutine: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID?
    /// Optional revision scope. Nil keeps legacy project-owned routines
    /// readable while a published plan revision can carry an immutable
    /// routine structure alongside its phases and sessions.
    public var planRevisionID: UUID?
    public var planSeriesID: UUID?
    public var isStructuralLocked: Bool
    public var name: String
    public var symbolName: String
    public var color: PracticeSemanticColor
    public var targetMinutes: Int
    public var weekdays: Set<Int>
    /// Empty keeps legacy flat routines readable. New writes should carry
    /// ordered blocks; `migratedToBlocks()` supplies a stable single block
    /// for legacy values.
    public var blocks: [PracticeBlock]
    public var reminderTime: PracticeReminderTime?
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        projectId: UUID? = nil,
        planRevisionID: UUID? = nil,
        planSeriesID: UUID? = nil,
        isStructuralLocked: Bool = false,
        name: String,
        symbolName: String,
        color: PracticeSemanticColor,
        targetMinutes: Int,
        weekdays: Set<Int>,
        blocks: [PracticeBlock] = [],
        reminderTime: PracticeReminderTime? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.projectId = projectId
        self.planRevisionID = planRevisionID
        self.planSeriesID = planSeriesID
        self.isStructuralLocked = isStructuralLocked
        self.name = name.trimmedForJournal
        self.symbolName = symbolName.trimmedForJournal
        self.color = color
        self.targetMinutes = targetMinutes
        self.weekdays = weekdays
        self.blocks = blocks
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
        normalized.blocks = try blocks.map { try $0.validated() }
        return normalized
    }

    public var orderedBlocks: [PracticeBlock] {
        blocks.sorted {
            if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Converts a legacy flat routine to one stable block without changing
    /// routine identity or its overall target. A non-flat routine needs no
    /// migration and returns nil.
    public func migratedToBlocks() -> PracticeRoutine? {
        guard blocks.isEmpty else { return nil }
        var migrated = self
        migrated.blocks = [
            PracticeBlock(
                id: id,
                name: name,
                targetMinutes: targetMinutes,
                ordinal: 0
            )
        ]
        return migrated
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, planRevisionID, planSeriesID, isStructuralLocked
        case name, symbolName, color, targetMinutes, weekdays, blocks, reminderTime
        case isArchived, createdAt, updatedAt, deletedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            projectId: try container.decodeIfPresent(UUID.self, forKey: .projectId),
            planRevisionID: try container.decodeIfPresent(UUID.self, forKey: .planRevisionID),
            planSeriesID: try container.decodeIfPresent(UUID.self, forKey: .planSeriesID),
            isStructuralLocked: try container.decodeIfPresent(Bool.self, forKey: .isStructuralLocked) ?? false,
            name: try container.decode(String.self, forKey: .name),
            symbolName: try container.decode(String.self, forKey: .symbolName),
            color: try container.decode(PracticeSemanticColor.self, forKey: .color),
            targetMinutes: try container.decode(Int.self, forKey: .targetMinutes),
            weekdays: try container.decode(Set<Int>.self, forKey: .weekdays),
            blocks: try container.decodeIfPresent([PracticeBlock].self, forKey: .blocks) ?? [],
            reminderTime: try container.decodeIfPresent(PracticeReminderTime.self, forKey: .reminderTime),
            isArchived: try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            deletedAt: try container.decodeIfPresent(Date.self, forKey: .deletedAt),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(planRevisionID, forKey: .planRevisionID)
        try container.encodeIfPresent(planSeriesID, forKey: .planSeriesID)
        try container.encode(isStructuralLocked, forKey: .isStructuralLocked)
        try container.encode(name, forKey: .name)
        try container.encode(symbolName, forKey: .symbolName)
        try container.encode(color, forKey: .color)
        try container.encode(targetMinutes, forKey: .targetMinutes)
        try container.encode(weekdays, forKey: .weekdays)
        if !blocks.isEmpty { try container.encode(blocks, forKey: .blocks) }
        try container.encodeIfPresent(reminderTime, forKey: .reminderTime)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }
}

public struct PracticeSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var routineId: UUID
    public var linkedProjectId: UUID?
    public var startedAt: Date
    public var endedAt: Date
    public var activeDurationSeconds: Int
    public var segments: [PracticeSegment]
    public var summary: PracticeSummary?
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
        segments: [PracticeSegment] = [],
        summary: PracticeSummary? = nil,
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
        self.segments = segments
        self.summary = summary
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
        normalized.segments = try segments.map { try $0.validated() }
        if let summary {
            guard summary.totalActiveDurationSeconds >= 0 else {
                throw PracticeValidationError.invalidSessionTiming
            }
            normalized.summary = summary
        }
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, routineId, linkedProjectId, startedAt, endedAt, activeDurationSeconds
        case segments, summary
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
            segments: try container.decodeIfPresent([PracticeSegment].self, forKey: .segments) ?? [],
            summary: try container.decodeIfPresent(PracticeSummary.self, forKey: .summary),
            note: try container.decodeIfPresent(String.self, forKey: .note),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            deletedAt: try container.decodeIfPresent(Date.self, forKey: .deletedAt),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(routineId, forKey: .routineId)
        try container.encodeIfPresent(linkedProjectId, forKey: .linkedProjectId)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(activeDurationSeconds, forKey: .activeDurationSeconds)
        if !segments.isEmpty { try container.encode(segments, forKey: .segments) }
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }
}
