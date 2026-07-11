import Foundation
import SwiftData

public struct JournalSnapshot: Codable, Equatable, Sendable {
    public var projects: [Project]
    public var sessions: [LearningSession]
    public var proofs: [Proof]
    public var reviews: [Review]
    public var trailEvents: [TrailEvent]
    public var coursePlans: [CoursePlan]
    public var planPhases: [PlanPhase]
    public var plannedSessions: [PlannedSession]
    public var hasCompletedOnboarding: Bool
    public var pendingFirstRecordProjectId: UUID?

    public init(
        projects: [Project] = [],
        sessions: [LearningSession] = [],
        proofs: [Proof] = [],
        reviews: [Review] = [],
        trailEvents: [TrailEvent] = [],
        coursePlans: [CoursePlan] = [],
        planPhases: [PlanPhase] = [],
        plannedSessions: [PlannedSession] = [],
        hasCompletedOnboarding: Bool? = nil,
        pendingFirstRecordProjectId: UUID? = nil
    ) {
        self.projects = projects
        self.sessions = sessions
        self.proofs = proofs
        self.reviews = reviews
        self.trailEvents = trailEvents
        self.coursePlans = coursePlans
        self.planPhases = planPhases
        self.plannedSessions = plannedSessions
        self.hasCompletedOnboarding = hasCompletedOnboarding ?? !projects.isEmpty
        self.pendingFirstRecordProjectId = pendingFirstRecordProjectId
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case sessions
        case proofs
        case reviews
        case trailEvents
        case coursePlans
        case planPhases
        case plannedSessions
        case hasCompletedOnboarding
        case pendingFirstRecordProjectId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        sessions = try container.decodeIfPresent([LearningSession].self, forKey: .sessions) ?? []
        proofs = try container.decodeIfPresent([Proof].self, forKey: .proofs) ?? []
        reviews = try container.decodeIfPresent([Review].self, forKey: .reviews) ?? []
        trailEvents = try container.decodeIfPresent([TrailEvent].self, forKey: .trailEvents) ?? []
        coursePlans = try container.decodeIfPresent([CoursePlan].self, forKey: .coursePlans) ?? []
        planPhases = try container.decodeIfPresent([PlanPhase].self, forKey: .planPhases) ?? []
        plannedSessions = try container.decodeIfPresent([PlannedSession].self, forKey: .plannedSessions) ?? []
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)
            ?? !projects.isEmpty
        pendingFirstRecordProjectId = try container.decodeIfPresent(UUID.self, forKey: .pendingFirstRecordProjectId)
    }
}

public protocol JournalStore: AnyObject {
    func load() throws -> JournalSnapshot
    func save(_ snapshot: JournalSnapshot) throws
}

public final class InMemoryJournalStore: JournalStore {
    private var storedSnapshot: JournalSnapshot

    public init(snapshot: JournalSnapshot = JournalSnapshot()) {
        self.storedSnapshot = snapshot
    }

    public func load() throws -> JournalSnapshot {
        storedSnapshot
    }

    public func save(_ snapshot: JournalSnapshot) throws {
        storedSnapshot = snapshot
    }
}

public final class JSONJournalStore: JournalStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> JournalSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return JournalSnapshot()
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(JournalSnapshot.self, from: data)
    }

    public func save(_ snapshot: JournalSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }
}

public enum SwiftDataJournalStoreError: Error, Equatable, Sendable {
    case invalidStoredValue
}

public final class SwiftDataJournalStore: JournalStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public convenience init(url: URL) throws {
        let configuration = ModelConfiguration(url: url)
        try self.init(container: Self.makeContainer(configuration: configuration))
    }

    public static func inMemory() throws -> SwiftDataJournalStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try SwiftDataJournalStore(container: makeContainer(configuration: configuration))
    }

    public func load() throws -> JournalSnapshot {
        let metadata = try context.fetch(FetchDescriptor<StoredJournalMetadata>()).first
        let projects = try context.fetch(FetchDescriptor<StoredProject>())
            .sorted(by: Self.sortByOrdinal)
            .map { $0.domain() }
        let sessions = try context.fetch(FetchDescriptor<StoredSession>())
            .sorted(by: Self.sortByOrdinal)
            .map { try $0.domain() }
        let proofs = try context.fetch(FetchDescriptor<StoredProof>())
            .sorted(by: Self.sortByOrdinal)
            .map { try $0.domain() }
        let reviews = try context.fetch(FetchDescriptor<StoredReview>())
            .sorted(by: Self.sortByOrdinal)
            .map { try $0.domain() }
        let trailEvents = try context.fetch(FetchDescriptor<StoredTrailEvent>())
            .sorted(by: Self.sortByOrdinal)
            .map { try $0.domain() }

        return JournalSnapshot(
            projects: projects,
            sessions: sessions,
            proofs: proofs,
            reviews: reviews,
            trailEvents: trailEvents,
            hasCompletedOnboarding: metadata?.hasCompletedOnboarding ?? !projects.isEmpty,
            pendingFirstRecordProjectId: metadata?.pendingFirstRecordProjectID.flatMap(UUID.init(uuidString:))
        )
    }

    public func save(_ snapshot: JournalSnapshot) throws {
        try deleteAll(StoredProject.self)
        try deleteAll(StoredSession.self)
        try deleteAll(StoredProof.self)
        try deleteAll(StoredReview.self)
        try deleteAll(StoredTrailEvent.self)
        try deleteAll(StoredJournalMetadata.self)

        for (ordinal, project) in snapshot.projects.enumerated() {
            context.insert(StoredProject(project: project, ordinal: ordinal))
        }
        for (ordinal, session) in snapshot.sessions.enumerated() {
            context.insert(StoredSession(session: session, ordinal: ordinal))
        }
        for (ordinal, proof) in snapshot.proofs.enumerated() {
            context.insert(StoredProof(proof: proof, ordinal: ordinal))
        }
        for (ordinal, review) in snapshot.reviews.enumerated() {
            context.insert(try StoredReview(review: review, ordinal: ordinal))
        }
        for (ordinal, trailEvent) in snapshot.trailEvents.enumerated() {
            context.insert(StoredTrailEvent(event: trailEvent, ordinal: ordinal))
        }
        context.insert(
            StoredJournalMetadata(
                hasCompletedOnboarding: snapshot.hasCompletedOnboarding,
                pendingFirstRecordProjectID: snapshot.pendingFirstRecordProjectId?.uuidString
            )
        )
        try context.save()
    }

    private static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: StoredProject.self,
            StoredSession.self,
            StoredProof.self,
            StoredReview.self,
            StoredTrailEvent.self,
            StoredJournalMetadata.self,
            configurations: configuration
        )
    }

    private func deleteAll<T: PersistentModel>(_ model: T.Type) throws {
        let records = try context.fetch(FetchDescriptor<T>())
        for record in records {
            context.delete(record)
        }
    }

    private static func sortByOrdinal<T: StoredOrdinal>(_ left: T, _ right: T) -> Bool {
        left.ordinal < right.ordinal
    }
}

private protocol StoredOrdinal {
    var ordinal: Int { get }
}

@Model
private final class StoredProject: StoredOrdinal {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var name: String
    var area: String
    var goal: String
    var statusRaw: String
    var currentNextStep: String
    var lastActionTypeRaw: String
    var defaultDurationMinutes: Int
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?

    init(project: Project, ordinal: Int) {
        id = project.id
        self.ordinal = ordinal
        name = project.name
        area = project.area
        goal = project.goal
        statusRaw = project.status.rawValue
        currentNextStep = project.currentNextStep
        lastActionTypeRaw = project.lastActionType.rawValue
        defaultDurationMinutes = project.defaultDurationMinutes
        createdAt = project.createdAt
        updatedAt = project.updatedAt
        archivedAt = project.archivedAt
    }

    func domain() -> Project {
        Project(
            id: id,
            name: name,
            area: area,
            goal: goal,
            status: ProjectStatus(rawValue: statusRaw) ?? .active,
            currentNextStep: currentNextStep,
            lastActionType: ActionType(rawValue: lastActionTypeRaw) ?? .course,
            defaultDurationMinutes: defaultDurationMinutes,
            createdAt: createdAt,
            updatedAt: updatedAt,
            archivedAt: archivedAt
        )
    }
}

@Model
private final class StoredSession: StoredOrdinal {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var projectID: UUID
    var sourceRaw: String
    var actionTypeRaw: String
    var startedAt: Date
    var endedAt: Date
    var durationMinutes: Int
    var note: String
    var nextStepBefore: String
    var nextStepAfter: String
    var createdAt: Date
    var updatedAt: Date

    init(session: LearningSession, ordinal: Int) {
        id = session.id
        self.ordinal = ordinal
        projectID = session.projectId
        sourceRaw = session.source.rawValue
        actionTypeRaw = session.actionType.rawValue
        startedAt = session.startedAt
        endedAt = session.endedAt
        durationMinutes = session.durationMinutes
        note = session.note
        nextStepBefore = session.nextStepBefore
        nextStepAfter = session.nextStepAfter
        createdAt = session.createdAt
        updatedAt = session.updatedAt
    }

    func domain() throws -> LearningSession {
        guard let source = SessionSource(rawValue: sourceRaw),
              let actionType = ActionType(rawValue: actionTypeRaw)
        else {
            throw SwiftDataJournalStoreError.invalidStoredValue
        }
        return try LearningSession(
            id: id,
            projectId: projectID,
            source: source,
            actionType: actionType,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMinutes: durationMinutes,
            note: note,
            nextStepBefore: nextStepBefore,
            nextStepAfter: nextStepAfter,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

@Model
private final class StoredProof: StoredOrdinal {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var projectID: UUID
    var sessionID: UUID?
    var typeRaw: String
    var title: String
    var statement: String
    var localPath: String?
    var urlString: String?
    var mimeType: String?
    var fileSize: Int?
    var createdAt: Date
    var updatedAt: Date

    init(proof: Proof, ordinal: Int) {
        id = proof.id
        self.ordinal = ordinal
        projectID = proof.projectId
        sessionID = proof.sessionId
        typeRaw = proof.type.rawValue
        title = proof.title
        statement = proof.statement
        localPath = proof.localPath
        urlString = proof.url?.absoluteString
        mimeType = proof.mimeType
        fileSize = proof.fileSize
        createdAt = proof.createdAt
        updatedAt = proof.updatedAt
    }

    func domain() throws -> Proof {
        guard let type = ProofType(rawValue: typeRaw) else {
            throw SwiftDataJournalStoreError.invalidStoredValue
        }
        return try Proof(
            id: id,
            projectId: projectID,
            sessionId: sessionID,
            type: type,
            title: title,
            statement: statement,
            localPath: localPath,
            url: urlString.flatMap(URL.init(string:)),
            mimeType: mimeType,
            fileSize: fileSize,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

@Model
private final class StoredReview: StoredOrdinal {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var periodStart: Date
    var periodEnd: Date
    var factsData: Data
    var patternsData: Data
    var decisionsData: Data
    var projectRecommendationsData: Data
    var nextStepsData: Data
    var aiSourceSummaryData: Data
    var sourceReferencesData: Data
    var createdAt: Date
    var updatedAt: Date

    init(review: Review, ordinal: Int) throws {
        id = review.id
        self.ordinal = ordinal
        periodStart = review.periodStart
        periodEnd = review.periodEnd
        factsData = try JSONEncoder.journal.encode(review.facts)
        patternsData = try JSONEncoder.journal.encode(review.patterns)
        decisionsData = try JSONEncoder.journal.encode(review.decisions)
        projectRecommendationsData = try JSONEncoder.journal.encode(review.projectRecommendations)
        nextStepsData = try JSONEncoder.journal.encode(review.nextSteps)
        aiSourceSummaryData = try JSONEncoder.journal.encode(review.aiSourceSummary)
        sourceReferencesData = try JSONEncoder.journal.encode(review.sourceReferences)
        createdAt = review.createdAt
        updatedAt = review.updatedAt
    }

    func domain() throws -> Review {
        let decoder = JSONDecoder.journal
        return Review(
            id: id,
            periodStart: periodStart,
            periodEnd: periodEnd,
            facts: try decoder.decode([String].self, from: factsData),
            patterns: try decoder.decode([String].self, from: patternsData),
            decisions: try decoder.decode([String].self, from: decisionsData),
            projectRecommendations: try decoder.decode([UUID: ProjectStatus].self, from: projectRecommendationsData),
            nextSteps: try decoder.decode([UUID: String].self, from: nextStepsData),
            aiSourceSummary: try decoder.decode([String].self, from: aiSourceSummaryData),
            sourceReferences: try decoder.decode([String: [String]].self, from: sourceReferencesData),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

@Model
private final class StoredTrailEvent: StoredOrdinal {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var projectID: UUID
    var typeRaw: String
    var sourceID: UUID
    var occurredAt: Date
    var title: String
    var detail: String

    init(event: TrailEvent, ordinal: Int) {
        id = event.id
        self.ordinal = ordinal
        projectID = event.projectId
        typeRaw = event.type.rawValue
        sourceID = event.sourceId
        occurredAt = event.occurredAt
        title = event.title
        detail = event.detail
    }

    func domain() throws -> TrailEvent {
        guard let type = TrailEventType(rawValue: typeRaw) else {
            throw SwiftDataJournalStoreError.invalidStoredValue
        }
        return TrailEvent(
            id: id,
            projectId: projectID,
            type: type,
            sourceId: sourceID,
            occurredAt: occurredAt,
            title: title,
            detail: detail
        )
    }
}

@Model
private final class StoredJournalMetadata {
    @Attribute(.unique) var key: String
    var hasCompletedOnboarding: Bool
    var pendingFirstRecordProjectID: String?

    init(hasCompletedOnboarding: Bool, pendingFirstRecordProjectID: String?) {
        key = "journal"
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.pendingFirstRecordProjectID = pendingFirstRecordProjectID
    }
}

public enum JournalStoreFactory {
    public static func makeDefault(documentsDirectory: URL) throws -> SwiftDataJournalStore {
        let journalDirectory = documentsDirectory.appendingPathComponent(
            "LearningJournal",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )

        let store = try SwiftDataJournalStore(
            url: journalDirectory.appendingPathComponent("journal.store")
        )
        let existingSnapshot = try store.load()
        let legacyURL = journalDirectory.appendingPathComponent("journal.json")
        guard existingSnapshot.isEmpty, FileManager.default.fileExists(atPath: legacyURL.path) else {
            return store
        }

        let legacySnapshot = try JSONJournalStore(fileURL: legacyURL).load()
        if !legacySnapshot.isEmpty {
            try store.save(legacySnapshot)
        }
        return store
    }
}

private extension JournalSnapshot {
    var isEmpty: Bool {
        projects.isEmpty
            && sessions.isEmpty
            && proofs.isEmpty
            && reviews.isEmpty
            && trailEvents.isEmpty
            && !hasCompletedOnboarding
            && pendingFirstRecordProjectId == nil
    }
}
