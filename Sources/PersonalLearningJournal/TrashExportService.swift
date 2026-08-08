import Foundation

public struct TrashExportDocument: Equatable, Identifiable, Sendable {
    public let url: URL
    public let attachmentCount: Int

    public var id: URL { url }

    public init(url: URL, attachmentCount: Int) {
        self.url = url
        self.attachmentCount = attachmentCount
    }
}

/// Creates one shareable archive before a Trash item is permanently deleted.
/// The public `prepare` seam is intentionally injectable by tests and by UI flows
/// that need to choose a different export directory.
public struct TrashExportService {
    private let archiveService: JournalArchiveService

    public init(archiveService: JournalArchiveService = JournalArchiveService()) {
        self.archiveService = archiveService
    }

    public func prepare(
        snapshot: JournalSnapshot,
        project: Project,
        to directory: URL
    ) throws -> TrashExportDocument {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let selectedSnapshot = selectedProjectSnapshot(projectID: project.id, snapshot: snapshot)
        var attachments: [String: Data] = [:]
        for proof in selectedSnapshot.proofs {
            let localPath: String?
            if let path = proof.localPath {
                localPath = path
            } else if case let .attachment(path, _, _) = proof.artifact {
                localPath = path
            } else {
                localPath = nil
            }
            guard let localPath else { continue }
            let sourceURL = URL(fileURLWithPath: localPath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw JournalArchiveError.missingAttachment(localPath)
            }
            let path = ExportService().attachmentExportPath(for: proof)
            do {
                attachments[path] = try Data(contentsOf: sourceURL)
            } catch {
                throw JournalArchiveError.missingAttachment(localPath)
            }
        }

        let envelope = try archiveService.export(
            snapshot: selectedSnapshot,
            attachments: attachments,
            password: nil,
            allowUnencrypted: true
        )
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "trash-" + project.id.uuidString + "-" + stamp + ".learningjournal"
        let url = directory.appendingPathComponent(filename)
        let data = try JSONEncoder.journal.encode(envelope)
        try data.write(to: url, options: [.atomic])
        return TrashExportDocument(url: url, attachmentCount: attachments.count)
    }

    private func selectedProjectSnapshot(
        projectID: UUID,
        snapshot: JournalSnapshot
    ) -> JournalSnapshot {
        let sessions = snapshot.sessions.filter { $0.projectId == projectID }
        let sessionIDs = Set(sessions.map(\.id))
        let proofs = snapshot.proofs.filter {
            $0.projectId == projectID || $0.sessionId.map(sessionIDs.contains) == true
        }
        let contracts = snapshot.evidenceContracts.filter { $0.projectId == projectID }
        let contractIDs = Set(contracts.map(\.id))
        let proofIDs = Set(proofs.map(\.id))
        let acceptances = snapshot.evidenceAcceptances.filter {
            contractIDs.contains($0.contractId) || proofIDs.contains($0.proofId)
        }
        let revisions = snapshot.proofRevisions.filter { proofIDs.contains($0.proofId) }
        let reviews = snapshot.reviews.compactMap { review -> Review? in
            guard review.projectRecommendations.keys.contains(projectID)
                    || review.nextSteps.keys.contains(projectID) else { return nil }
            var scoped = review
            scoped.projectRecommendations = scoped.projectRecommendations.filter { $0.key == projectID }
            scoped.nextSteps = scoped.nextSteps.filter { $0.key == projectID }
            return scoped
        }
        let decisions = snapshot.reviewDecisions.filter { $0.projectId == projectID }
        let trails = snapshot.trailEvents.filter { $0.projectId == projectID }
        let plans = snapshot.coursePlans.filter { $0.projectId == projectID }
        let planIDs = Set(plans.map(\.id))
        let phases = snapshot.planPhases.filter { planIDs.contains($0.planId) }
        let plannedSessions = snapshot.plannedSessions.filter {
            $0.projectId == projectID || planIDs.contains($0.planId)
        }
        let routines = snapshot.practiceRoutines.filter { $0.projectId == projectID }
        let routineIDs = Set(routines.map(\.id))
        let practiceSessions = snapshot.practiceSessions.filter {
            routineIDs.contains($0.routineId) || $0.linkedProjectId == projectID
        }
        return JournalSnapshot(
            projects: snapshot.projects.filter { $0.id == projectID },
            sessions: sessions,
            proofs: proofs,
            reviews: reviews,
            evidenceContracts: contracts,
            evidenceAcceptances: acceptances,
            proofRevisions: revisions,
            reviewDecisions: decisions,
            trailEvents: trails,
            coursePlans: plans,
            planPhases: phases,
            plannedSessions: plannedSessions,
            availabilityRules: [],
            schedulingPreferences: [],
            practiceRoutines: routines,
            practiceSessions: practiceSessions,
            hasCompletedOnboarding: snapshot.hasCompletedOnboarding,
            pendingFirstRecordProjectId: snapshot.pendingFirstRecordProjectId == projectID
                ? projectID
                : nil
        )
    }
}
