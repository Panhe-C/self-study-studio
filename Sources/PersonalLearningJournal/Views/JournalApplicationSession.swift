import Combine
import Foundation

@MainActor
public final class JournalApplicationSession: ObservableObject {
    @Published public private(set) var viewModel: JournalViewModel
    @Published public private(set) var calendarViewModel: CalendarViewModel
    @Published public private(set) var pendingMigration: MigrationDryRun?
    @Published public private(set) var migrationError: String?

    private let documentsDirectory: URL
    private let accountCoordinator: CloudAccountCoordinator
    private let accountProvider: any CloudAccountProviding
    private let practiceTimer: PracticeTimerRuntime
    private var migrationRepository: any JournalRepository
    private var migrationResolutions: [UUID: ProjectStatusMigrationResolution] = [:]

    public init(
        documentsDirectory: URL,
        accountProvider: any CloudAccountProviding = SystemCloudAccountProvider()
    ) {
        self.documentsDirectory = documentsDirectory
        self.accountCoordinator = CloudAccountCoordinator(rootDirectory: documentsDirectory)
        self.accountProvider = accountProvider
        self.practiceTimer = PracticeTimerRuntime(
            store: UserDefaultsPracticeTimerStateStore()
        )
        if let localRepository = accountCoordinator.activeRepository {
            Self.migrateLegacyStore(
                documentsDirectory: documentsDirectory,
                into: localRepository
            )
        }
        let repository = accountCoordinator.activeRepository ?? InMemoryJournalRepository()
        self.migrationRepository = repository
        self.pendingMigration = nil
        self.migrationError = nil
        self.calendarViewModel = CalendarViewModel(
            repository: repository,
            calendarClient: EventKitCalendarClient()
        )
        self.viewModel = Self.makeViewModel(
            repository: repository,
            accountCoordinator: accountCoordinator,
            practiceTimer: practiceTimer
        )
        prepareMigrationGate(for: repository)

        Task { [weak self] in
            await self?.refreshAccount()
        }
    }

    public func refreshAccount() async {
        await accountCoordinator.refresh(using: accountProvider)
        guard let repository = accountCoordinator.activeRepository else { return }
        migrationRepository = repository
        rebuildViewModels(using: repository)
        prepareMigrationGate(for: repository)
        if case .cloud = accountCoordinator.state.mode {
            await viewModel.refreshSyncSummary()
            try? await viewModel.syncNow()
        } else {
            await viewModel.refreshSyncSummary()
        }
    }

    public func resolveArchivedProject(
        projectID: UUID,
        resolution: ProjectStatusMigrationResolution
    ) {
        migrationResolutions[projectID] = resolution
    }

    public func clearMigrationError() {
        migrationError = nil
    }

    public func continueMigration() {
        let resolutions: [MigrationResolution] = migrationResolutions.map {
            .project($0.key, $0.value)
        }
        continueMigration(with: resolutions)
    }

    public func continueMigration(with resolutions: [MigrationResolution]) {
        guard pendingMigration != nil else { return }
        do {
            let snapshot = try migrationRepository.snapshot()
            let backupDirectory = documentsDirectory
                .appendingPathComponent("LearningJournal", isDirectory: true)
                .appendingPathComponent("Migrations", isDirectory: true)
                .appendingPathComponent("B1", isDirectory: true)
            _ = try ProductConvergenceMigration().execute(
                snapshot: snapshot,
                resolutions: resolutions,
                repository: migrationRepository,
                backupDirectory: backupDirectory
            )
            migrationError = nil
            migrationResolutions = [:]
            pendingMigration = nil
            rebuildViewModels(using: migrationRepository)
        } catch {
            migrationError = error.localizedDescription
        }
    }

    private func prepareMigrationGate(for repository: any JournalRepository) {
        guard (try? repository.hasCompletedMigration(
            identifier: ProductConvergenceMigration.statusMigrationIdentifier
        )) != true else {
            pendingMigration = nil
            return
        }
        guard let snapshot = try? repository.snapshot() else { return }
        let dryRun = ProductConvergenceMigration().dryRun(snapshot: snapshot)
        let hasLegacyStatus = snapshot.projects.contains {
            $0.status.isLegacy || $0.isTrashed
        }
        pendingMigration = dryRun.issues.isEmpty && !hasLegacyStatus ? nil : dryRun
    }

    private func rebuildViewModels(using repository: any JournalRepository) {
        calendarViewModel = CalendarViewModel(
            repository: repository,
            calendarClient: EventKitCalendarClient()
        )
        viewModel = Self.makeViewModel(
            repository: repository,
            accountCoordinator: accountCoordinator,
            practiceTimer: practiceTimer
        )
    }

    private static func makeViewModel(
        repository: any JournalRepository,
        accountCoordinator: CloudAccountCoordinator,
        practiceTimer: PracticeTimerRuntime
    ) -> JournalViewModel {
        let journalService = JournalService(repository: repository)
        let syncCoordinator: (any CloudSyncCoordinating)?
        if case .cloud = accountCoordinator.state.mode {
            let stateSerializationData = try? repository.syncChangeToken()
            syncCoordinator = CloudSyncCoordinator(
                repository: repository,
                client: CKSyncEngineDatabaseClient(
                    stateSerializationData: stateSerializationData
                )
            )
        } else {
            syncCoordinator = nil
        }

        return JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(
                journalService: journalService,
                provider: AdaptiveAIReviewProvider()
            ),
            exportService: ExportService(),
            practiceService: PracticeService(repository: repository),
            practiceTimer: practiceTimer,
            coursePlanningService: CoursePlanningService(repository: repository),
            syncCoordinator: syncCoordinator,
            syncRepository: repository,
            accountCoordinator: accountCoordinator
        )
    }

    private static func migrateLegacyStore(
        documentsDirectory: URL,
        into repository: any JournalRepository
    ) {
        do {
            let legacyStore = try JournalStoreFactory.makeDefault(
                documentsDirectory: documentsDirectory
            )
            let backupDirectory = documentsDirectory
                .appendingPathComponent("LearningJournal", isDirectory: true)
            try RepositoryMigration().migrateIfNeeded(
                from: legacyStore,
                to: repository,
                backupDirectory: backupDirectory
            )
        } catch {
            // The journal remains usable with its current repository when a legacy import is unavailable.
        }
    }
}
