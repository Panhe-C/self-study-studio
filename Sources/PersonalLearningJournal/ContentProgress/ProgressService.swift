import Foundation

public extension ContentProgress {
    static func createProject(
        name: String,
        titles: [String],
        now: Date = Date(),
        makeID: () -> UUID = UUID.init
    ) throws -> Project {
        let units = titles.enumerated().map { index, title in
            LearningUnit(id: makeID(), title: trimmed(title), order: index)
        }
        let project = Project(id: makeID(), name: trimmed(name), createdAt: now, updatedAt: now, units: units)
        try validate(project)
        return project
    }

    static func setCompleted(
        _ project: Project, unitID: UUID, completed: Bool, now: Date = Date()
    ) throws -> Project {
        guard !project.isPaused else { throw ValidationError.pausedProject }
        guard let index = project.units.firstIndex(where: { $0.id == unitID }) else {
            throw ValidationError.missingUnit
        }
        if project.units[index].isCompleted == completed { return project }
        var updated = project
        updated.units[index].isCompleted = completed
        updated.units[index].completedAt = completed ? now : nil
        updated.updatedAt = max(now, project.updatedAt)
        try validate(updated)
        return updated
    }

    static func addUnit(
        _ project: Project, title: String, id: UUID = UUID(), now: Date = Date()
    ) throws -> Project {
        var updated = project
        updated.units.append(LearningUnit(id: id, title: trimmed(title), order: project.units.count))
        updated.updatedAt = max(now, project.updatedAt)
        try validate(updated)
        return updated
    }

    static func renameUnit(
        _ project: Project, unitID: UUID, title: String, now: Date = Date()
    ) throws -> Project {
        guard let index = project.units.firstIndex(where: { $0.id == unitID }) else {
            throw ValidationError.missingUnit
        }
        let normalized = trimmed(title)
        if project.units[index].title == normalized { return project }
        var updated = project
        updated.units[index].title = normalized
        updated.updatedAt = max(now, project.updatedAt)
        try validate(updated)
        return updated
    }

    static func deleteUnit(
        _ project: Project, unitID: UUID, now: Date = Date()
    ) throws -> Project {
        guard project.units.contains(where: { $0.id == unitID }) else {
            throw ValidationError.missingUnit
        }
        var updated = project
        updated.units.removeAll { $0.id == unitID }
        normalizeOrder(&updated)
        updated.updatedAt = max(now, project.updatedAt)
        try validate(updated)
        return updated
    }

    static func reorder(
        _ project: Project, ids: [UUID], now: Date = Date()
    ) throws -> Project {
        guard ids.count == project.units.count,
              Set(ids).count == ids.count,
              Set(ids) == Set(project.units.map(\.id)) else {
            throw ValidationError.invalidReorder
        }
        if ids == project.units.map(\.id) { return project }
        let byID = Dictionary(uniqueKeysWithValues: project.units.map { ($0.id, $0) })
        var updated = project
        updated.units = ids.compactMap { byID[$0] }
        normalizeOrder(&updated)
        updated.updatedAt = max(now, project.updatedAt)
        try validate(updated)
        return updated
    }

    static func setPaused(
        _ project: Project, paused: Bool, now: Date = Date()
    ) throws -> Project {
        if project.isPaused == paused { return project }
        var updated = project
        updated.isPaused = paused
        updated.updatedAt = max(now, project.updatedAt)
        try validate(updated)
        return updated
    }

    private static func normalizeOrder(_ project: inout Project) {
        for index in project.units.indices { project.units[index].order = index }
    }
}
