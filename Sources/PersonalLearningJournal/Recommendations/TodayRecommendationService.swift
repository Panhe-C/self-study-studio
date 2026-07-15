import Foundation

public enum TodayRecommendationReason: Int, Codable, CaseIterable, Sendable {
    case userPinned = 0
    case contractBoundary = 1
    case confirmedSchedule = 2
    case staleProject = 3
}

public struct TodayRecommendation: Equatable, Identifiable, Sendable {
    public var id: UUID { projectId }
    public var projectId: UUID
    public var reason: TodayRecommendationReason
    public var dueDate: Date?
    public var lastMeaningfulActivity: Date
    public var projectCreatedAt: Date
    public var isPrimary: Bool

    public init(
        projectId: UUID,
        reason: TodayRecommendationReason,
        dueDate: Date?,
        lastMeaningfulActivity: Date,
        projectCreatedAt: Date,
        isPrimary: Bool = false
    ) {
        self.projectId = projectId
        self.reason = reason
        self.dueDate = dueDate
        self.lastMeaningfulActivity = lastMeaningfulActivity
        self.projectCreatedAt = projectCreatedAt
        self.isPrimary = isPrimary
    }
}

public struct TodayRecommendationService: Sendable {
    private let pinnedProjectIDs: Set<UUID>

    public init(pinnedProjectIDs: Set<UUID> = []) {
        self.pinnedProjectIDs = pinnedProjectIDs
    }

    public func recommendations(
        snapshot: JournalSnapshot,
        now: Date = Date(),
        limit: Int = 3
    ) -> [TodayRecommendation] {
        let contracts = Dictionary(uniqueKeysWithValues: snapshot.evidenceContracts.map { ($0.id, $0) })
        let sessions = Dictionary(grouping: snapshot.sessions.filter { $0.deletedAt == nil }, by: \.projectId)
        let proofs = Dictionary(grouping: snapshot.proofs.filter { $0.deletedAt == nil }, by: \.projectId)
        let planned = Dictionary(grouping: snapshot.plannedSessions.filter {
            $0.deletedAt == nil && $0.status == .scheduled
        }, by: \.projectId)

        let ranked = snapshot.projects
            .filter(\.canContinue)
            .map { project -> TodayRecommendation in
                let activity = [
                    project.createdAt,
                    sessions[project.id, default: []].map(\.endedAt).max(),
                    proofs[project.id, default: []].map(\.createdAt).max()
                ].compactMap { $0 }.max() ?? project.createdAt
                if pinnedProjectIDs.contains(project.id) {
                    return TodayRecommendation(
                        projectId: project.id,
                        reason: .userPinned,
                        dueDate: nil,
                        lastMeaningfulActivity: activity,
                        projectCreatedAt: project.createdAt
                    )
                }
                if let contractID = project.activeEvidenceContractId,
                   let contract = contracts[contractID],
                   let boundary = nextUnresolvedBoundary(
                       contract: contract,
                       acceptances: snapshot.evidenceAcceptances,
                       now: now
                   ) {
                    return TodayRecommendation(
                        projectId: project.id,
                        reason: .contractBoundary,
                        dueDate: boundary,
                        lastMeaningfulActivity: activity,
                        projectCreatedAt: project.createdAt
                    )
                }
                if let scheduled = planned[project.id, default: []].sorted(by: scheduleOrder).first {
                    return TodayRecommendation(
                        projectId: project.id,
                        reason: .confirmedSchedule,
                        dueDate: scheduled.deadline,
                        lastMeaningfulActivity: activity,
                        projectCreatedAt: project.createdAt
                    )
                }
                return TodayRecommendation(
                    projectId: project.id,
                    reason: .staleProject,
                    dueDate: nil,
                    lastMeaningfulActivity: activity,
                    projectCreatedAt: project.createdAt
                )
            }
            .sorted(by: recommendationOrder)

        return Array(ranked.prefix(min(3, max(0, limit)))).enumerated().map { index, value in
            var recommendation = value
            recommendation.isPrimary = index == 0
            return recommendation
        }
    }

    private func nextUnresolvedBoundary(
        contract: EvidenceContract,
        acceptances: [EvidenceAcceptance],
        now: Date
    ) -> Date? {
        guard contract.isActive else { return nil }
        switch contract.trigger {
        case let .interval(days):
            let acceptedCount = acceptances.filter {
                $0.contractId == contract.id && $0.deletedAt == nil
            }.count
            let boundary = contract.startsAt.addingTimeInterval(
                TimeInterval((acceptedCount + 1) * days * 86_400)
            )
            return boundary <= now ? boundary : nil
        case .milestone:
            return nil
        }
    }

    private func scheduleOrder(_ left: PlannedSession, _ right: PlannedSession) -> Bool {
        let leftDue = left.deadline ?? .distantFuture
        let rightDue = right.deadline ?? .distantFuture
        if leftDue != rightDue { return leftDue < rightDue }
        if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        return left.id.uuidString < right.id.uuidString
    }

    private func recommendationOrder(_ left: TodayRecommendation, _ right: TodayRecommendation) -> Bool {
        if left.reason.rawValue != right.reason.rawValue {
            return left.reason.rawValue < right.reason.rawValue
        }
        let leftDue = left.dueDate ?? .distantFuture
        let rightDue = right.dueDate ?? .distantFuture
        if leftDue != rightDue { return leftDue < rightDue }
        if left.lastMeaningfulActivity != right.lastMeaningfulActivity {
            return left.lastMeaningfulActivity < right.lastMeaningfulActivity
        }
        if left.projectCreatedAt != right.projectCreatedAt {
            return left.projectCreatedAt < right.projectCreatedAt
        }
        return left.projectId.uuidString < right.projectId.uuidString
    }
}
