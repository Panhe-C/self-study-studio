import CryptoKit
import Foundation

public enum JournalArchiveError: Error, Equatable, Sendable {
    case unencryptedExportRequiresConfirmation
    case passwordRequired
    case invalidArchive
    case unsupportedFormatVersion(Int)
    case checksumMismatch
    case duplicateIdentifiers
    case unsafeAttachmentPath(String)
}

public struct JournalArchiveManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var createdAt: Date
    public var recordCounts: [String: Int]
    public var checksums: [String: String]
}

public struct JournalArchiveEnvelope: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var salt: Data?
    public var derivationRounds: Int?
    public var sealedPayload: Data
    public var encrypted: Bool
}

public struct JournalArchivePreview: Equatable, Sendable {
    public var manifest: JournalArchiveManifest
    public var snapshot: JournalSnapshot
    public var attachmentData: [String: Data]
    public var duplicateIDs: Set<UUID>
    public var checksumsValid: Bool
}

public struct JournalArchiveRestore: Equatable, Sendable {
    public var snapshot: JournalSnapshot
    public var attachmentData: [String: Data]
}

public struct TrashPurgeImpact: Equatable, Sendable {
    public var projectID: UUID
    public var sessionCount: Int
    public var proofCount: Int
    public var revisionCount: Int
    public var planCount: Int
    public var attachmentPaths: [String]
    public var references: [JournalEntityReference]
}

private struct JournalArchivePayload: Codable {
    var manifest: JournalArchiveManifest
    var snapshot: JournalSnapshot
    var attachments: [String: Data]
}

public struct JournalArchiveService {
    public static let formatVersion = 1

    private let now: () -> Date
    private let derivationRounds: Int

    public init(
        now: @escaping () -> Date = Date.init,
        derivationRounds: Int = 10_000
    ) {
        self.now = now
        self.derivationRounds = max(1, derivationRounds)
    }

    public func export(
        snapshot: JournalSnapshot,
        attachments: [String: Data],
        password: String?,
        allowUnencrypted: Bool = false
    ) throws -> JournalArchiveEnvelope {
        try validateAttachmentPaths(attachments.keys)
        let snapshotData = try Self.encoder.encode(snapshot)
        var checksums = ["snapshot.json": Self.digest(snapshotData)]
        for (path, data) in attachments {
            checksums["attachment:\(path)"] = Self.digest(data)
        }
        let manifest = JournalArchiveManifest(
            formatVersion: Self.formatVersion,
            createdAt: now(),
            recordCounts: recordCounts(snapshot),
            checksums: checksums
        )
        let payload = try Self.encoder.encode(
            JournalArchivePayload(manifest: manifest, snapshot: snapshot, attachments: attachments)
        )

        guard let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard allowUnencrypted else {
                throw JournalArchiveError.unencryptedExportRequiresConfirmation
            }
            return JournalArchiveEnvelope(
                formatVersion: Self.formatVersion,
                salt: nil,
                derivationRounds: nil,
                sealedPayload: payload,
                encrypted: false
            )
        }

        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = Self.deriveKey(password: password, salt: salt, rounds: derivationRounds)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw JournalArchiveError.invalidArchive }
        return JournalArchiveEnvelope(
            formatVersion: Self.formatVersion,
            salt: salt,
            derivationRounds: derivationRounds,
            sealedPayload: combined,
            encrypted: true
        )
    }

    public func preview(
        _ envelope: JournalArchiveEnvelope,
        password: String?
    ) throws -> JournalArchivePreview {
        guard envelope.formatVersion == Self.formatVersion else {
            throw JournalArchiveError.unsupportedFormatVersion(envelope.formatVersion)
        }
        let payloadData: Data
        if envelope.encrypted {
            guard let password, let salt = envelope.salt, let rounds = envelope.derivationRounds else {
                throw JournalArchiveError.passwordRequired
            }
            do {
                let box = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
                payloadData = try AES.GCM.open(
                    box,
                    using: Self.deriveKey(password: password, salt: salt, rounds: rounds)
                )
            } catch {
                throw JournalArchiveError.invalidArchive
            }
        } else {
            payloadData = envelope.sealedPayload
        }

        let payload: JournalArchivePayload
        do {
            payload = try Self.decoder.decode(JournalArchivePayload.self, from: payloadData)
        } catch {
            throw JournalArchiveError.invalidArchive
        }
        guard payload.manifest.formatVersion == Self.formatVersion else {
            throw JournalArchiveError.unsupportedFormatVersion(payload.manifest.formatVersion)
        }
        try validateAttachmentPaths(payload.attachments.keys)
        let checksumsValid = try checksumsAreValid(payload)
        guard checksumsValid else { throw JournalArchiveError.checksumMismatch }
        guard payload.manifest.recordCounts == recordCounts(payload.snapshot) else {
            throw JournalArchiveError.invalidArchive
        }

        return JournalArchivePreview(
            manifest: payload.manifest,
            snapshot: payload.snapshot,
            attachmentData: payload.attachments,
            duplicateIDs: duplicateIDs(in: payload.snapshot),
            checksumsValid: checksumsValid
        )
    }

    public func restore(_ preview: JournalArchivePreview) throws -> JournalArchiveRestore {
        guard preview.checksumsValid else { throw JournalArchiveError.checksumMismatch }
        guard preview.duplicateIDs.isEmpty else { throw JournalArchiveError.duplicateIdentifiers }
        try validateRelationships(in: preview.snapshot)
        return JournalArchiveRestore(snapshot: preview.snapshot, attachmentData: preview.attachmentData)
    }

    public func restore(
        _ preview: JournalArchivePreview,
        into repository: any JournalRepository
    ) throws {
        let restored = try restore(preview)
        try repository.commit(
            JournalTransaction(
                upserts: Self.entities(in: restored.snapshot),
                origin: .migration,
                stateMetadata: JournalStateMetadata(snapshot: restored.snapshot)
            )
        )
    }

    public func purgeImpact(projectID: UUID, snapshot: JournalSnapshot) -> TrashPurgeImpact {
        let sessions = snapshot.sessions.filter { $0.projectId == projectID }
        let sessionIDs = Set(sessions.map(\.id))
        let proofs = snapshot.proofs.filter { $0.projectId == projectID || $0.sessionId.map(sessionIDs.contains) == true }
        let proofIDs = Set(proofs.map(\.id))
        let contracts = snapshot.evidenceContracts.filter { $0.projectId == projectID }
        let contractIDs = Set(contracts.map(\.id))
        let acceptances = snapshot.evidenceAcceptances.filter {
            contractIDs.contains($0.contractId) || proofIDs.contains($0.proofId)
        }
        let revisions = snapshot.proofRevisions.filter { proofIDs.contains($0.proofId) }
        let decisions = snapshot.reviewDecisions.filter { $0.projectId == projectID }
        let trails = snapshot.trailEvents.filter { $0.projectId == projectID }
        let plans = snapshot.coursePlans.filter { $0.projectId == projectID }
        let planIDs = Set(plans.map(\.id))
        let phases = snapshot.planPhases.filter { planIDs.contains($0.planId) }
        let plannedSessions = snapshot.plannedSessions.filter { $0.projectId == projectID || planIDs.contains($0.planId) }
        var references = [JournalEntityReference(.project, projectID)]
        references += sessions.map { JournalEntityReference(.session, $0.id) }
        references += proofs.map { JournalEntityReference(.proof, $0.id) }
        references += contracts.map { JournalEntityReference(.evidenceContract, $0.id) }
        references += acceptances.map { JournalEntityReference(.evidenceAcceptance, $0.id) }
        references += revisions.map { JournalEntityReference(.proofRevision, $0.id) }
        references += decisions.map { JournalEntityReference(.reviewDecision, $0.id) }
        references += trails.map { JournalEntityReference(.trailEvent, $0.id) }
        references += plans.map { JournalEntityReference(.coursePlan, $0.id) }
        references += phases.map { JournalEntityReference(.planPhase, $0.id) }
        references += plannedSessions.map { JournalEntityReference(.plannedSession, $0.id) }
        return TrashPurgeImpact(
            projectID: projectID,
            sessionCount: sessions.count,
            proofCount: proofs.count,
            revisionCount: revisions.count,
            planCount: plans.count,
            attachmentPaths: proofs.compactMap(\.localPath).sorted(),
            references: references
        )
    }

    @discardableResult
    public func purge(
        projectID: UUID,
        snapshot: JournalSnapshot,
        from repository: any JournalRepository
    ) throws -> TrashPurgeImpact {
        guard snapshot.projects.contains(where: { $0.id == projectID && $0.status == .trash }) else {
            throw JournalArchiveError.invalidArchive
        }
        let impact = purgeImpact(projectID: projectID, snapshot: snapshot)
        try repository.commit(JournalTransaction(deletions: impact.references, origin: .user))
        return impact
    }

    public func automaticPurgeCandidates(
        snapshot: JournalSnapshot,
        now: Date? = nil,
        retentionDays: Int = 30
    ) -> Set<UUID> {
        let deadline = (now ?? self.now()).addingTimeInterval(-Double(retentionDays) * 86_400)
        return Set(snapshot.projects.compactMap { project in
            guard project.status == .trash, let deletedAt = project.deletedAt, deletedAt <= deadline else { return nil }
            return project.id
        })
    }

    private func checksumsAreValid(_ payload: JournalArchivePayload) throws -> Bool {
        guard payload.manifest.checksums["snapshot.json"] == Self.digest(try Self.encoder.encode(payload.snapshot)) else {
            return false
        }
        let expectedKeys = Set(payload.attachments.keys.map { "attachment:\($0)" })
            .union(["snapshot.json"])
        guard Set(payload.manifest.checksums.keys) == expectedKeys else { return false }
        return payload.attachments.allSatisfy { path, data in
            payload.manifest.checksums["attachment:\(path)"] == Self.digest(data)
        }
    }

    private func validateAttachmentPaths<S: Sequence>(_ paths: S) throws where S.Element == String {
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if path.isEmpty || path.hasPrefix("/") || components.contains("..") || components.contains("") {
                throw JournalArchiveError.unsafeAttachmentPath(path)
            }
        }
    }

    private func validateRelationships(in snapshot: JournalSnapshot) throws {
        let projects = Set(snapshot.projects.map(\.id))
        let sessions = Set(snapshot.sessions.map(\.id))
        guard snapshot.sessions.allSatisfy({ projects.contains($0.projectId) }) else {
            throw JournalArchiveError.invalidArchive
        }
        guard snapshot.proofs.allSatisfy({ proof in
            projects.contains(proof.projectId) && proof.sessionId.map(sessions.contains) != false
        }) else {
            throw JournalArchiveError.invalidArchive
        }
    }

    private func duplicateIDs(in snapshot: JournalSnapshot) -> Set<UUID> {
        var duplicates = Set<UUID>()
        func inspect(_ ids: [UUID]) {
            var seen = Set<UUID>()
            for id in ids where !seen.insert(id).inserted { duplicates.insert(id) }
        }
        for ids in Self.identifierGroups(in: snapshot) { inspect(ids) }
        return duplicates
    }

    private func recordCounts(_ snapshot: JournalSnapshot) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: zip(JournalEntityKind.allCases.map(\.rawValue), Self.identifierGroups(in: snapshot).map(\.count)))
    }

    private static func identifierGroups(in snapshot: JournalSnapshot) -> [[UUID]] {
        [snapshot.projects.map(\.id), snapshot.sessions.map(\.id), snapshot.proofs.map(\.id),
         snapshot.reviews.map(\.id), snapshot.evidenceContracts.map(\.id), snapshot.evidenceAcceptances.map(\.id),
         snapshot.proofRevisions.map(\.id), snapshot.reviewDecisions.map(\.id), snapshot.trailEvents.map(\.id),
         snapshot.coursePlans.map(\.id), snapshot.planPhases.map(\.id), snapshot.plannedSessions.map(\.id),
         snapshot.availabilityRules.map(\.id), snapshot.schedulingPreferences.map(\.id),
         snapshot.practiceRoutines.map(\.id), snapshot.practiceSessions.map(\.id)]
    }

    private static func entities(in snapshot: JournalSnapshot) -> [JournalEntity] {
        snapshot.projects.map(JournalEntity.project)
        + snapshot.sessions.map(JournalEntity.session)
        + snapshot.proofs.map(JournalEntity.proof)
        + snapshot.reviews.map(JournalEntity.review)
        + snapshot.evidenceContracts.map(JournalEntity.evidenceContract)
        + snapshot.evidenceAcceptances.map(JournalEntity.evidenceAcceptance)
        + snapshot.proofRevisions.map(JournalEntity.proofRevision)
        + snapshot.reviewDecisions.map(JournalEntity.reviewDecision)
        + snapshot.trailEvents.map(JournalEntity.trailEvent)
        + snapshot.coursePlans.map(JournalEntity.coursePlan)
        + snapshot.planPhases.map(JournalEntity.planPhase)
        + snapshot.plannedSessions.map(JournalEntity.plannedSession)
        + snapshot.availabilityRules.map(JournalEntity.availabilityRule)
        + snapshot.schedulingPreferences.map(JournalEntity.schedulingPreferences)
        + snapshot.practiceRoutines.map(JournalEntity.practiceRoutine)
        + snapshot.practiceSessions.map(JournalEntity.practiceSession)
    }

    private static func deriveKey(password: String, salt: Data, rounds: Int) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var material = passwordData + salt
        for _ in 0..<max(1, rounds) {
            material = Data(SHA256.hash(data: material + passwordData + salt))
        }
        return SymmetricKey(data: material)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }()
}
