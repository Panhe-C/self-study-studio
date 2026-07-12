import CloudKit
import CryptoKit
import Foundation

public protocol CloudAccountProviding: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func currentUserRecordName() async throws -> String?
}

public final class SystemCloudAccountProvider: CloudAccountProviding, @unchecked Sendable {
    private let container: CKContainer

    public init(containerIdentifier: String = CKSyncEngineDatabaseClient.defaultContainerIdentifier) {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    public func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    public func currentUserRecordName() async throws -> String? {
        try await container.userRecordID().recordName
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

@MainActor
public final class CloudAccountCoordinator {
    public typealias RepositoryFactoryClosure = (URL) throws -> any JournalRepository

    public private(set) var state: CloudAccountState
    public private(set) var activeRepository: (any JournalRepository)?

    private let rootDirectory: URL
    private let repositoryFactory: RepositoryFactoryClosure
    private var localRepository: (any JournalRepository)?

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
                let accountHash = Self.hash(recordName)
                try activate(scope: accountHash)
                state = CloudAccountState(mode: .cloud(accountHash: accountHash), lastCheckedAt: Date())
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

    public func confirmExistingLocalDataUpload() throws {
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

    private func entities(from snapshot: JournalSnapshot) -> [JournalEntity] {
        snapshot.projects.map(JournalEntity.project)
            + snapshot.sessions.map(JournalEntity.session)
            + snapshot.proofs.map(JournalEntity.proof)
            + snapshot.reviews.map(JournalEntity.review)
            + snapshot.trailEvents.map(JournalEntity.trailEvent)
            + snapshot.coursePlans.map(JournalEntity.coursePlan)
            + snapshot.planPhases.map(JournalEntity.planPhase)
            + snapshot.plannedSessions.map(JournalEntity.plannedSession)
            + snapshot.availabilityRules.map(JournalEntity.availabilityRule)
            + snapshot.schedulingPreferences.map(JournalEntity.schedulingPreferences)
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
