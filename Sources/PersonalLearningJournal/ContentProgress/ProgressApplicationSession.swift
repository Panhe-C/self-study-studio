import Combine
import Foundation

@MainActor
public final class ProgressApplicationSession: ObservableObject {
    @Published public private(set) var projects: [ContentProgress.Project] = []
    @Published public private(set) var drafts: [ContentProgress.Draft] = []
    @Published public private(set) var errorMessage: String?

    private var repository: (any ContentProgressRepository)?

    public init(documentsDirectory: URL) {
        do {
            repository = try SwiftDataProgressRepository(
                url: documentsDirectory.appendingPathComponent("ContentProgressV1.sqlite")
            )
            try reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func reload() throws {
        guard let repository else { throw StoreError.unavailable }
        // Publish only after both reads succeed. A damaged store is not an empty store.
        let loadedProjects = try repository.projects()
        let loadedDrafts = try repository.drafts()
        projects = loadedProjects
        drafts = loadedDrafts
        errorMessage = nil
    }

    @discardableResult
    public func startDraft() -> ContentProgress.Draft? {
        let draft = ContentProgress.Draft(name: "")
        return perform {
            guard let repository else { throw StoreError.unavailable }
            try repository.save(draft)
            try reload()
            return draft
        }
    }

    @discardableResult
    public func saveDraft(_ draft: ContentProgress.Draft) -> Bool {
        perform {
            guard let repository else { throw StoreError.unavailable }
            try repository.save(draft)
            try reload()
            return true
        } ?? false
    }

    public func discardDraft(id: UUID) {
        perform {
            guard let repository else { throw StoreError.unavailable }
            try repository.removeDraft(id: id)
            try reload()
        }
    }

    @discardableResult
    public func confirmDraft(id: UUID) -> ContentProgress.Project? {
        perform {
            guard let repository else { throw StoreError.unavailable }
            let project = try repository.confirmDraft(id: id, now: Date())
            try reload()
            return project
        }
    }

    public func updateProject(
        id: UUID,
        change: (ContentProgress.Project) throws -> ContentProgress.Project
    ) {
        perform {
            guard let repository else { throw StoreError.unavailable }
            guard let current = try repository.project(id: id) else { throw StoreError.missingProject }
            let updated = try change(current)
            try repository.save(updated)
            try reload()
        }
    }

    public func clearError() { errorMessage = nil }

    @discardableResult
    private func perform<T>(_ operation: () throws -> T) -> T? {
        do { return try operation() }
        catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private enum StoreError: LocalizedError {
        case unavailable, missingProject

        var errorDescription: String? {
            switch self {
            case .unavailable: "本地项目存储不可用，请检查设备存储后重试。"
            case .missingProject: "找不到此项目，请返回首页刷新。"
            }
        }
    }
}
