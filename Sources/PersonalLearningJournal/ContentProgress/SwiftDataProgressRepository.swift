import Foundation
import SwiftData

@Model
final class StoredProgressProject {
    @Attribute(.unique) var id: String
    var payload: Data

    init(id: String, payload: Data) {
        self.id = id
        self.payload = payload
    }
}

@Model
final class StoredProgressDraft {
    @Attribute(.unique) var id: String
    var payload: Data

    init(id: String, payload: Data) {
        self.id = id
        self.payload = payload
    }
}

@MainActor
public final class SwiftDataProgressRepository: ContentProgressRepository {
    private let context: ModelContext

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(url: url)
        let container = try ModelContainer(
            for: StoredProgressProject.self, StoredProgressDraft.self,
            configurations: configuration
        )
        context = ModelContext(container)
    }

    public static func inMemory() throws -> SwiftDataProgressRepository {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: StoredProgressProject.self, StoredProgressDraft.self,
            configurations: configuration
        )
        return SwiftDataProgressRepository(container: container)
    }

    private init(container: ModelContainer) {
        context = ModelContext(container)
    }

    public func projects() throws -> [ContentProgress.Project] {
        let records = try context.fetch(FetchDescriptor<StoredProgressProject>())
        return try records.map { try decodeProject($0.payload) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func project(id: UUID) throws -> ContentProgress.Project? {
        guard let record = try storedProject(id: id) else { return nil }
        return try decodeProject(record.payload)
    }

    public func save(_ project: ContentProgress.Project) throws {
        try ContentProgress.validate(project)
        let payload = try JSONEncoder.journal.encode(project)
        do {
            if let record = try storedProject(id: project.id) {
                record.payload = payload
            } else {
                context.insert(StoredProgressProject(id: project.id.uuidString, payload: payload))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func draft(id: UUID) throws -> ContentProgress.Draft? {
        guard let record = try storedDraft(id: id) else { return nil }
        return try decodeDraft(record.payload)
    }

    public func drafts() throws -> [ContentProgress.Draft] {
        let records = try context.fetch(FetchDescriptor<StoredProgressDraft>())
        return try records.map { try decodeDraft($0.payload) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ draft: ContentProgress.Draft) throws {
        let payload = try JSONEncoder.journal.encode(draft)
        do {
            if let record = try storedDraft(id: draft.id) {
                record.payload = payload
            } else {
                context.insert(StoredProgressDraft(id: draft.id.uuidString, payload: payload))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func removeDraft(id: UUID) throws {
        guard let record = try storedDraft(id: id) else { return }
        context.delete(record)
        do { try context.save() } catch {
            context.rollback()
            throw error
        }
    }

    public func confirmDraft(id: UUID, now: Date = Date()) throws -> ContentProgress.Project {
        if let existing = try project(id: id) {
            // A crash after commit must not create another project on retry.
            if let leftover = try storedDraft(id: id) {
                context.delete(leftover)
                do { try context.save() } catch { context.rollback(); throw error }
            }
            return existing
        }
        guard let draft = try draft(id: id), let record = try storedDraft(id: id) else {
            throw ContentProgress.RepositoryError.corruptedRecord
        }
        let project = try draft.confirmedProject(now: now)
        let payload = try JSONEncoder.journal.encode(project)
        context.insert(StoredProgressProject(id: project.id.uuidString, payload: payload))
        context.delete(record)
        do {
            try context.save()
            return project
        } catch {
            context.rollback()
            throw error
        }
    }

    private func storedProject(id: UUID) throws -> StoredProgressProject? {
        let key = id.uuidString
        return try context.fetch(FetchDescriptor<StoredProgressProject>(
            predicate: #Predicate { $0.id == key }
        )).first
    }

    private func storedDraft(id: UUID) throws -> StoredProgressDraft? {
        let key = id.uuidString
        return try context.fetch(FetchDescriptor<StoredProgressDraft>(
            predicate: #Predicate { $0.id == key }
        )).first
    }

    private func decodeProject(_ payload: Data) throws -> ContentProgress.Project {
        return try ContentProgress.decode(payload)
    }

    private func decodeDraft(_ payload: Data) throws -> ContentProgress.Draft {
        return try JSONDecoder.journal.decode(ContentProgress.Draft.self, from: payload)
    }
}
