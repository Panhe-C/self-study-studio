import Foundation

/// Pure value-type editing operations for a plan draft. All cross-object
/// consistency — phase ordinal renumbering, deleting a phase's sessions,
/// splicing a regenerated phase — lives here instead of in the views.
public enum CoursePlanDraftEditingService {
    public static func editPhase(
        _ draft: CoursePlanDraft,
        phaseID: String,
        _ transform: (inout CoursePlanDraftPhase) -> Void
    ) -> CoursePlanDraft {
        var result = draft
        guard let index = result.phases.firstIndex(where: { $0.id == phaseID }) else {
            return draft
        }
        transform(&result.phases[index])
        return result
    }

    /// Appends the phase and renumbers ordinals to match array position,
    /// consistent with `movePhase`.
    public static func addPhase(
        _ draft: CoursePlanDraft,
        phase: CoursePlanDraftPhase
    ) -> CoursePlanDraft {
        var result = draft
        result.phases.append(phase)
        renumberOrdinals(&result.phases)
        return result
    }

    /// Removes the phase together with its sessions and renumbers ordinals.
    public static func deletePhase(
        _ draft: CoursePlanDraft,
        phaseID: String
    ) -> CoursePlanDraft {
        var result = draft
        result.phases.removeAll { $0.id == phaseID }
        result.sessions.removeAll { $0.phaseID == phaseID }
        renumberOrdinals(&result.phases)
        return result
    }

    public static func movePhase(
        _ draft: CoursePlanDraft,
        phaseID: String,
        by offset: Int
    ) -> CoursePlanDraft {
        var result = draft
        guard let index = result.phases.firstIndex(where: { $0.id == phaseID }) else {
            return draft
        }
        let target = index + offset
        guard result.phases.indices.contains(target) else { return draft }
        result.phases.swapAt(index, target)
        renumberOrdinals(&result.phases)
        return result
    }

    public static func editSession(
        _ draft: CoursePlanDraft,
        sessionID: String,
        _ transform: (inout CoursePlanDraftSession) -> Void
    ) -> CoursePlanDraft {
        var result = draft
        guard let index = result.sessions.firstIndex(where: { $0.id == sessionID }) else {
            return draft
        }
        transform(&result.sessions[index])
        return result
    }

    public static func addSession(
        _ draft: CoursePlanDraft,
        session: CoursePlanDraftSession
    ) -> CoursePlanDraft {
        var result = draft
        result.sessions.append(session)
        return result
    }

    public static func deleteSession(
        _ draft: CoursePlanDraft,
        sessionID: String
    ) -> CoursePlanDraft {
        var result = draft
        result.sessions.removeAll { $0.id == sessionID }
        return result
    }

    public static func moveSession(
        _ draft: CoursePlanDraft,
        sessionID: String,
        by offset: Int
    ) -> CoursePlanDraft {
        var result = draft
        guard let index = result.sessions.firstIndex(where: { $0.id == sessionID }) else {
            return draft
        }
        let target = index + offset
        guard result.sessions.indices.contains(target) else { return draft }
        result.sessions.swapAt(index, target)
        return result
    }

    /// Splices a single-phase regeneration into the draft: only the target
    /// phase (keeping its position and ordinal) and its sessions are
    /// replaced. Other phases and their sessions keep their identity, text,
    /// and relative order. Regenerated sessions receive fresh draft-scoped
    /// ids and are appended after the surviving sessions.
    public static func replacingPhase(
        _ draft: CoursePlanDraft,
        phaseID: String,
        with regeneration: CoursePlanPhaseRegeneration,
        sessionIDGenerator: () -> String = { "session-\(UUID().uuidString)" }
    ) -> CoursePlanDraft {
        guard let index = draft.phases.firstIndex(where: { $0.id == phaseID }) else {
            return draft
        }
        var result = draft
        var phase = regeneration.phase
        phase.ordinal = result.phases[index].ordinal
        result.phases[index] = phase
        result.sessions = result.sessions.filter { $0.phaseID != phaseID }
        var replacementSessions = regeneration.sessions
        for sessionIndex in replacementSessions.indices {
            replacementSessions[sessionIndex].id = sessionIDGenerator()
            replacementSessions[sessionIndex].phaseID = phase.id
        }
        result.sessions.append(contentsOf: replacementSessions)
        return result
    }

    private static func renumberOrdinals(_ phases: inout [CoursePlanDraftPhase]) {
        for index in phases.indices {
            phases[index].ordinal = index
        }
    }
}

/// Value-type reducer state for draft review: the current draft plus a stack
/// of snapshots. Every mutation pushes the previous draft, so `undo()`
/// restores the most recent edit.
public struct CoursePlanDraftEditingState: Equatable, Sendable {
    public private(set) var draft: CoursePlanDraft
    private var undoStack: [CoursePlanDraft]

    public init(draft: CoursePlanDraft) {
        self.draft = draft
        self.undoStack = []
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    public mutating func apply(_ transform: (CoursePlanDraft) -> CoursePlanDraft) {
        undoStack.append(draft)
        draft = transform(draft)
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        draft = previous
        return true
    }
}
