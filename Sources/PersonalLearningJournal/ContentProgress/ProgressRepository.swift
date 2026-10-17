import Foundation

public extension ContentProgress {
    struct DraftUnit: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var title: String

        public init(id: UUID = UUID(), title: String) {
            self.id = id
            self.title = title
        }
    }

    struct Draft: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var outlineText: String
        public var courseURL: String?
        public var units: [DraftUnit]
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: UUID = UUID(), name: String, outlineText: String = "",
            courseURL: String? = nil, units: [DraftUnit] = [],
            createdAt: Date = Date(), updatedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.outlineText = outlineText
            self.courseURL = courseURL
            self.units = units
            self.createdAt = ContentProgress.millisecondPrecision(createdAt)
            self.updatedAt = max(ContentProgress.millisecondPrecision(updatedAt), self.createdAt)
        }

        public func confirmedProject(now: Date = Date()) throws -> Project {
            let project = Project(
                id: id,
                name: ContentProgress.trimmed(name),
                createdAt: createdAt,
                updatedAt: max(ContentProgress.millisecondPrecision(now), createdAt),
                units: units.enumerated().map { index, unit in
                    LearningUnit(id: unit.id, title: ContentProgress.trimmed(unit.title), order: index)
                }
            )
            try ContentProgress.validate(project)
            return project
        }
    }

    enum RepositoryError: Error, Equatable, Sendable {
        case alreadyConfirmed
        case corruptedRecord
    }
}

@MainActor
public protocol ContentProgressRepository: AnyObject {
    func projects() throws -> [ContentProgress.Project]
    func project(id: UUID) throws -> ContentProgress.Project?
    func save(_ project: ContentProgress.Project) throws
    func draft(id: UUID) throws -> ContentProgress.Draft?
    func drafts() throws -> [ContentProgress.Draft]
    func save(_ draft: ContentProgress.Draft) throws
    func removeDraft(id: UUID) throws
    /// Project upsert and draft removal share one local transaction.
    func confirmDraft(id: UUID, now: Date) throws -> ContentProgress.Project
}
