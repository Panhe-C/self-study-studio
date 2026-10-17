import Foundation

public extension ContentProgress {
    struct Projection: Equatable, Sendable {
        public let total: Int
        public let completed: Int
        public let percentage: Int
        public let currentUnitID: UUID?
        public let nextUnitID: UUID?
        public let isAllCompleted: Bool
    }

    static func projection(for project: Project) -> Projection {
        let completed = project.units.filter(\.isCompleted).count
        let remaining = project.units.filter { !$0.isCompleted }
        let total = project.units.count
        return Projection(
            total: total,
            completed: completed,
            percentage: total == 0 ? 0 : (completed * 100 + total / 2) / total,
            currentUnitID: remaining.first?.id,
            nextUnitID: remaining.dropFirst().first?.id,
            isAllCompleted: total > 0 && completed == total
        )
    }
}
