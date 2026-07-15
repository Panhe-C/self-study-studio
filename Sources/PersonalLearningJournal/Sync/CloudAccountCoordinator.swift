import CloudKit
import CryptoKit
import Foundation

public protocol CloudAccountProviding: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func currentUserRecordName() async throws -> String?
}

public final class SystemCloudAccountProvider: CloudAccountProviding, @unchecked Sendable {
    private let hasCloudKitEntitlement: @Sendable () -> Bool
    private let accountStatusLoader: @Sendable () async throws -> CKAccountStatus
    private let userRecordNameLoader: @Sendable () async throws -> String?

    public init(containerIdentifier: String = CKSyncEngineDatabaseClient.defaultContainerIdentifier) {
        self.hasCloudKitEntitlement = Self.processHasCloudKitEntitlement
        self.accountStatusLoader = {
            try await CKContainer(identifier: containerIdentifier).accountStatus()
        }
        self.userRecordNameLoader = {
            try await CKContainer(identifier: containerIdentifier).userRecordID().recordName
        }
    }

    init(
        hasCloudKitEntitlement: @escaping @Sendable () -> Bool,
        accountStatusLoader: @escaping @Sendable () async throws -> CKAccountStatus,
        userRecordNameLoader: @escaping @Sendable () async throws -> String?
    ) {
        self.hasCloudKitEntitlement = hasCloudKitEntitlement
        self.accountStatusLoader = accountStatusLoader
        self.userRecordNameLoader = userRecordNameLoader
    }

    public func accountStatus() async throws -> CKAccountStatus {
        guard hasCloudKitEntitlement() else { return .noAccount }
        return try await accountStatusLoader()
    }

    public func currentUserRecordName() async throws -> String? {
        guard hasCloudKitEntitlement() else { return nil }
        return try await userRecordNameLoader()
    }

    private static func processHasCloudKitEntitlement() -> Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}

public enum CloudAccountMode: Equatable, Sendable {
    case checking
    case localOnly
    case cloud(accountHash: String)
    case restricted
    case unavailable
}

public struct CloudAccountState: Equatable, Sendable {
    public var mode: CloudAccountMode
    public var lastCheckedAt: Date?
    public var message: String?

    public init(mode: CloudAccountMode = .checking, lastCheckedAt: Date? = nil, message: String? = nil) {
        self.mode = mode
        self.lastCheckedAt = lastCheckedAt
        self.message = message
    }
}

public enum AccountSpace: Equatable, Sendable {
    case local
    case account(String)
}

public enum AccountSpaceTransferChoice: Sendable {
    case move
    case copy
    case keepLocal
}

public struct AccountSpaceTransferPreview: Equatable, Sendable {
    public var sourceRecordCount: Int
    public var sourceAttachmentCount: Int
    public var duplicateIDs: Set<UUID>
    public var archiveURL: URL
}

public struct AccountSpaceTransition: Equatable, Sendable {
    public var source: AccountSpace
    public var destination: AccountSpace
    public var preview: AccountSpaceTransferPreview?
    public var requiresTransferChoice: Bool { preview != nil }
}

@MainActor
public final class CloudAccountCoordinator {
    public typealias RepositoryFactoryClosure = (URL) throws -> any JournalRepository

    public private(set) var state: CloudAccountState
    public private(set) var activeRepository: (any JournalRepository)?

    private let rootDirectory: URL
    private let repositoryFactory: RepositoryFactoryClosure
    private var localRepository: (any JournalRepository)?
    private var pendingTransfer: (
        source: any JournalRepository,
        destination: any JournalRepository,
        snapshot: JournalSnapshot
    )?

    public init(
        rootDirectory: URL,
        repositoryFactory: @escaping RepositoryFactoryClosure = { url in
            try RepositoryFactory.makeDefault(storeURL: url)
        }
    ) {
        self.rootDirectory = rootDirectory
        self.repositoryFactory = repositoryFactory
        self.state = CloudAccountState(mode: .checking)
        let localRepository = try? repositoryFactory(
            Self.storeURL(rootDirectory: rootDirectory, scope: "local")
        )
        self.localRepository = localRepository ?? InMemoryJournalRepository()
        self.activeRepository = self.localRepository
    }

    public func refresh(using provider: any CloudAccountProviding) async {
        state = CloudAccountState(mode: .checking)
        do {
            switch try await provider.accountStatus() {
            case .available:
                guard let recordName = try await provider.currentUserRecordName(), !recordName.isEmpty else {
                    setLocalOnly(message: "iCloud account identity is unavailable")
                    return
                }
                _ = try await transition(from: .local, to: .account(recordName))
            case .noAccount:
                setLocalOnly(message: nil)
            case .restricted:
                state = CloudAccountState(mode: .restricted, lastCheckedAt: Date())
            case .couldNotDetermine, .temporarilyUnavailable:
                state = CloudAccountState(mode: .unavailable, lastCheckedAt: Date(), message: "iCloud account status is unavailable")
            @unknown default:
                state = CloudAccountState(mode: .unavailable, lastCheckedAt: Date())
            }
        } catch {
            state = CloudAccountState(mode: .unavailable, lastCheckedAt: Date(), message: "Unable to check iCloud account")
        }
    }

    public func storeURL(forAccountRecordName recordName: String) -> URL {
        Self.storeURL(rootDirectory: rootDirectory, scope: Self.hash(recordName))
    }

    public func prepareExistingLocalDataForCloud() throws -> Int {
        entities(from: try localRepository?.snapshot() ?? JournalSnapshot()).count
    }

    public func transition(
        from sourceSpace: AccountSpace,
        to destinationSpace: AccountSpace
    ) async throws -> AccountSpaceTransition {
        let source = try repository(for: sourceSpace)
        let sourceSnapshot = try source.snapshot()
        let destination = try repository(for: destinationSpace)
        activeRepository = destination
        switch destinationSpace {
        case .local:
            state = CloudAccountState(mode: .localOnly, lastCheckedAt: Date())
        case let .account(recordName):
            state = CloudAccountState(mode: .cloud(accountHash: Self.hash(recordName)), lastCheckedAt: Date())
        }

        let sourceEntities = entities(from: sourceSnapshot)
        guard !sourceEntities.isEmpty else {
            pendingTransfer = nil
            return AccountSpaceTransition(source: sourceSpace, destination: destinationSpace, preview: nil)
        }
        let destinationReferences = Set(entities(from: try destination.snapshot()).map(\.reference))
        let duplicateIDs = Set(sourceEntities.compactMap { entity in
            destinationReferences.contains(entity.reference) ? entity.reference.id : nil
        })
        let archiveURL = try writeTransferArchive(snapshot: sourceSnapshot)
        pendingTransfer = (source, destination, sourceSnapshot)
        return AccountSpaceTransition(
            source: sourceSpace,
            destination: destinationSpace,
            preview: AccountSpaceTransferPreview(
                sourceRecordCount: sourceEntities.count,
                sourceAttachmentCount: sourceSnapshot.proofs.count { $0.localPath != nil },
                duplicateIDs: duplicateIDs,
                archiveURL: archiveURL
            )
        )
    }

    public func completeTransfer(choice: AccountSpaceTransferChoice) throws {
        guard let pendingTransfer else { return }
        defer { self.pendingTransfer = nil }
        switch choice {
        case .keepLocal:
            return
        case .copy, .move:
            let sourceEntities = entities(from: pendingTransfer.snapshot)
            try pendingTransfer.destination.commit(
                JournalTransaction(
                    upserts: sourceEntities,
                    origin: .user,
                    stateMetadata: JournalStateMetadata(snapshot: pendingTransfer.snapshot)
                )
            )
            if case .move = choice {
                try pendingTransfer.source.commit(
                    JournalTransaction(deletions: sourceEntities.map(\.reference), origin: .user)
                )
            }
        }
    }

    public func confirmExistingLocalDataUpload() throws {
        if pendingTransfer != nil {
            try completeTransfer(choice: .copy)
            return
        }
        guard let activeRepository else { return }
        let snapshot = try localRepository?.snapshot() ?? JournalSnapshot()
        try activeRepository.commit(JournalTransaction(
            upserts: entities(from: snapshot),
            origin: .user,
            stateMetadata: JournalStateMetadata(snapshot: snapshot)
        ))
    }

    private func setLocalOnly(message: String?) {
        do {
            try activate(scope: "local")
        } catch {
            activeRepository = InMemoryJournalRepository()
        }
        state = CloudAccountState(mode: .localOnly, lastCheckedAt: Date(), message: message)
    }

    private func activate(scope: String) throws {
        if scope == "local" {
            activeRepository = localRepository
            return
        }
        activeRepository = nil
        activeRepository = try repositoryFactory(Self.storeURL(rootDirectory: rootDirectory, scope: scope))
    }

    private func repository(for space: AccountSpace) throws -> any JournalRepository {
        switch space {
        case .local:
            if let localRepository { return localRepository }
            let repository = try repositoryFactory(Self.storeURL(rootDirectory: rootDirectory, scope: "local"))
            localRepository = repository
            return repository
        case let .account(recordName):
            return try repositoryFactory(Self.storeURL(rootDirectory: rootDirectory, scope: Self.hash(recordName)))
        }
    }

    private func writeTransferArchive(snapshot: JournalSnapshot) throws -> URL {
        let directory = rootDirectory.appendingPathComponent("TransferArchives", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("account-transfer-\(UUID().uuidString).journalarchive")
        let envelope = try JournalArchiveService().export(
            snapshot: snapshot,
            attachments: [:],
            password: nil,
            allowUnencrypted: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(envelope).write(to: url, options: [.atomic])
        return url
    }

    private func entities(from snapshot: JournalSnapshot) -> [JournalEntity] {
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

    private static func storeURL(rootDirectory: URL, scope: String) -> URL {
        rootDirectory
            .appendingPathComponent("LearningJournal", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
            .appendingPathComponent("journal-v2.store")
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
