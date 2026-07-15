import Foundation

public enum ProjectCommitmentState: String, Codable, CaseIterable, Sendable {
    case ready
    case needsSetup
}

public enum ProjectActivationIssue: String, Codable, Equatable, Sendable {
    case missingGoal
    case missingNextStep
    case missingContract
}

public extension Project {
    var countsTowardAttentionBudget: Bool {
        status == .active
            && commitmentState == .ready
            && activeEvidenceContractId != nil
            && deletedAt == nil
    }

    func activationIssues(contract: EvidenceContract?) -> [ProjectActivationIssue] {
        var issues: [ProjectActivationIssue] = []
        if goal.trimmedForJournal.isEmpty {
            issues.append(.missingGoal)
        }
        if currentNextStep.trimmedForJournal.isEmpty {
            issues.append(.missingNextStep)
        }
        if contract?.projectId != id || contract?.isActive != true {
            issues.append(.missingContract)
        }
        return issues
    }
}
