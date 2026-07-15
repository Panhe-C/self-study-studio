import Foundation

public struct JournalExport: Codable, Equatable, Sendable {
    public var version: String
    public var exportedAt: Date
    public var projects: [Project]
    public var sessions: [LearningSession]
    public var proofs: [Proof]
    public var reviews: [Review]
    public var evidenceContracts: [EvidenceContract]
    public var evidenceAcceptances: [EvidenceAcceptance]
    public var proofRevisions: [ProofRevision]
    public var reviewDecisions: [ReviewDecision]
    public var trailEvents: [TrailEvent]
    public var coursePlans: [CoursePlan]
    public var planPhases: [PlanPhase]
    public var plannedSessions: [PlannedSession]
    public var availabilityRules: [AvailabilityRule]
    public var schedulingPreferences: [SchedulingPreferences]
    public var practiceRoutines: [PracticeRoutine]
    public var practiceSessions: [PracticeSession]

    public init(
        version: String = "v0.2",
        exportedAt: Date = Date(),
        projects: [Project],
        sessions: [LearningSession],
        proofs: [Proof],
        reviews: [Review],
        evidenceContracts: [EvidenceContract] = [],
        evidenceAcceptances: [EvidenceAcceptance] = [],
        proofRevisions: [ProofRevision] = [],
        reviewDecisions: [ReviewDecision] = [],
        trailEvents: [TrailEvent] = [],
        coursePlans: [CoursePlan] = [],
        planPhases: [PlanPhase] = [],
        plannedSessions: [PlannedSession] = [],
        availabilityRules: [AvailabilityRule] = [],
        schedulingPreferences: [SchedulingPreferences] = [],
        practiceRoutines: [PracticeRoutine] = [],
        practiceSessions: [PracticeSession] = []
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.projects = projects
        self.sessions = sessions
        self.proofs = proofs
        self.reviews = reviews
        self.evidenceContracts = evidenceContracts
        self.evidenceAcceptances = evidenceAcceptances
        self.proofRevisions = proofRevisions
        self.reviewDecisions = reviewDecisions
        self.trailEvents = trailEvents
        self.coursePlans = coursePlans
        self.planPhases = planPhases
        self.plannedSessions = plannedSessions
        self.availabilityRules = availabilityRules
        self.schedulingPreferences = schedulingPreferences
        self.practiceRoutines = practiceRoutines
        self.practiceSessions = practiceSessions
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case exportedAt
        case projects
        case sessions
        case proofs
        case reviews
        case evidenceContracts
        case evidenceAcceptances
        case proofRevisions
        case reviewDecisions
        case trailEvents
        case coursePlans
        case planPhases
        case plannedSessions
        case availabilityRules
        case schedulingPreferences
        case practiceRoutines
        case practiceSessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        projects = try container.decode([Project].self, forKey: .projects)
        sessions = try container.decode([LearningSession].self, forKey: .sessions)
        proofs = try container.decode([Proof].self, forKey: .proofs)
        reviews = try container.decode([Review].self, forKey: .reviews)
        evidenceContracts = try container.decodeIfPresent([EvidenceContract].self, forKey: .evidenceContracts) ?? []
        evidenceAcceptances = try container.decodeIfPresent([EvidenceAcceptance].self, forKey: .evidenceAcceptances) ?? []
        proofRevisions = try container.decodeIfPresent([ProofRevision].self, forKey: .proofRevisions) ?? []
        reviewDecisions = try container.decodeIfPresent([ReviewDecision].self, forKey: .reviewDecisions) ?? []
        trailEvents = try container.decodeIfPresent([TrailEvent].self, forKey: .trailEvents) ?? []
        coursePlans = try container.decode([CoursePlan].self, forKey: .coursePlans)
        planPhases = try container.decode([PlanPhase].self, forKey: .planPhases)
        plannedSessions = try container.decode([PlannedSession].self, forKey: .plannedSessions)
        availabilityRules = try container.decode([AvailabilityRule].self, forKey: .availabilityRules)
        schedulingPreferences = try container.decode([SchedulingPreferences].self, forKey: .schedulingPreferences)
        practiceRoutines = try container.decodeIfPresent([PracticeRoutine].self, forKey: .practiceRoutines) ?? []
        practiceSessions = try container.decodeIfPresent([PracticeSession].self, forKey: .practiceSessions) ?? []
    }
}

public struct JournalExportBundle: Equatable, Sendable {
    public var jsonURL: URL
    public var attachmentURLs: [URL]

    public init(jsonURL: URL, attachmentURLs: [URL]) {
        self.jsonURL = jsonURL
        self.attachmentURLs = attachmentURLs
    }
}

public struct ExportService {
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func exportJSON(snapshot: JournalSnapshot) throws -> Data {
        let exportProofs = snapshot.proofs.map { proof in
            var exportProof = proof
            exportProof.localPath = nil
            return exportProof
        }
        let export = JournalExport(
            exportedAt: now(),
            projects: snapshot.projects,
            sessions: snapshot.sessions,
            proofs: exportProofs,
            reviews: snapshot.reviews,
            evidenceContracts: snapshot.evidenceContracts,
            evidenceAcceptances: snapshot.evidenceAcceptances,
            proofRevisions: snapshot.proofRevisions,
            reviewDecisions: snapshot.reviewDecisions,
            trailEvents: snapshot.trailEvents,
            coursePlans: snapshot.coursePlans,
            planPhases: snapshot.planPhases,
            plannedSessions: snapshot.plannedSessions,
            availabilityRules: snapshot.availabilityRules,
            schedulingPreferences: snapshot.schedulingPreferences,
            practiceRoutines: snapshot.practiceRoutines,
            practiceSessions: snapshot.practiceSessions
        )
        return try JSONEncoder.journal.encode(export)
    }

    public func exportBundle(
        snapshot: JournalSnapshot,
        to exportDirectory: URL
    ) throws -> JournalExportBundle {
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )

        let jsonURL = exportDirectory.appendingPathComponent("journal.json")
        let jsonData = try exportJSON(snapshot: snapshot)
        try jsonData.write(to: jsonURL, options: [.atomic])

        let attachmentURLs = try exportAttachments(
            snapshot: snapshot,
            to: exportDirectory
        )

        return JournalExportBundle(
            jsonURL: jsonURL,
            attachmentURLs: attachmentURLs
        )
    }

    public func attachmentExportPath(for proof: Proof) -> String {
        let sessionComponent = proof.sessionId?.uuidString ?? "project"
        let fileExtension = proof.localPath
            .map { URL(fileURLWithPath: $0).pathExtension }
            .flatMap { $0.isEmpty ? nil : $0 }
        let fileName = fileExtension.map { "\(proof.id.uuidString).\($0)" } ?? proof.id.uuidString

        return [
            "Attachments",
            proof.projectId.uuidString,
            sessionComponent,
            fileName
        ].joined(separator: "/")
    }

    public func exportAttachments(
        snapshot: JournalSnapshot,
        to exportDirectory: URL
    ) throws -> [URL] {
        var copiedFiles: [URL] = []

        for proof in snapshot.proofs {
            guard let localPath = proof.localPath else { continue }
            let sourceURL = URL(fileURLWithPath: localPath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

            let relativePath = attachmentExportPath(for: proof)
            let destinationURL = exportDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            copiedFiles.append(destinationURL)
        }

        return copiedFiles
    }
}

public extension JSONEncoder {
    static var journal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var journal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
