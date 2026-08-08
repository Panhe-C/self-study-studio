import Combine
import Foundation

@MainActor
public final class JournalApplicationSession: ObservableObject {
    @Published public private(set) var viewModel: JournalViewModel
    @Published public private(set) var calendarViewModel: CalendarViewModel
    @Published public private(set) var pendingMigration: MigrationDryRun?
    @Published public private(set) var pendingPlanRevisionMigration: PlanRevisionMigrationDryRun?
    @Published public private(set) var pendingPracticeBlocksMigration: PracticeBlocksMigrationDryRun?
    @Published public private(set) var migrationError: String?
    @Published public private(set) var migrationGateBlocked = false

    private let documentsDirectory: URL
    private let accountCoordinator: CloudAccountCoordinator
    private let accountProvider: any CloudAccountProviding
    private let practiceTimer: PracticeTimerRuntime
    private let repositoryOverride: (any JournalRepository)?
    private var migrationRepository: any JournalRepository
    private var migrationResolutions: [UUID: ProjectStatusMigrationResolution] = [:]
    private var proofMigrationResolutions: [UUID: ProofMigrationResolution] = [:]
    private var practiceMigrationResolutions: [UUID: PracticeMigrationResolution] = [:]
    private var practiceBlocksMigrationResolutions: [UUID: PracticeBlocksMigrationResolution] = [:]

    public init(
        documentsDirectory: URL,
        accountProvider: any CloudAccountProviding = SystemCloudAccountProvider(),
        repositoryOverride: (any JournalRepository)? = nil
    ) {
        self.documentsDirectory = documentsDirectory
        self.accountCoordinator = CloudAccountCoordinator(rootDirectory: documentsDirectory)
        self.accountProvider = accountProvider
        self.repositoryOverride = repositoryOverride
        self.practiceTimer = PracticeTimerRuntime(
            store: UserDefaultsPracticeTimerStateStore()
        )
        if repositoryOverride == nil, let localRepository = accountCoordinator.activeRepository {
            Self.migrateLegacyStore(
                documentsDirectory: documentsDirectory,
                into: localRepository
            )
        }
        let repository = repositoryOverride ?? accountCoordinator.activeRepository ?? InMemoryJournalRepository()
        self.migrationRepository = repository
        self.pendingMigration = nil
        self.pendingPlanRevisionMigration = nil
        self.pendingPracticeBlocksMigration = nil
        self.migrationError = nil
        self.migrationGateBlocked = false
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
        guard let repository = repositoryOverride ?? accountCoordinator.activeRepository else {
            migrationGateBlocked = true
            migrationError = "The journal repository is unavailable. Retry to continue safely."
            return
        }
        migrationRepository = repository
        rebuildViewModels(using: repository)
        prepareMigrationGate(for: repository)
        if case .cloud = accountCoordinator.state.mode,
           !migrationGateBlocked,
           pendingMigration == nil,
           pendingPlanRevisionMigration == nil,
           pendingPracticeBlocksMigration == nil {
            await viewModel.refreshSyncSummary()
            try? await viewModel.syncNow()
        } else if !migrationGateBlocked {
            await viewModel.refreshSyncSummary()
        }
    }

    public func resolveArchivedProject(
        projectID: UUID,
        resolution: ProjectStatusMigrationResolution
    ) {
        migrationResolutions[projectID] = resolution
    }

    public func resolveProof(
        proofID: UUID,
        resolution: ProofMigrationResolution
    ) {
        proofMigrationResolutions[proofID] = resolution
    }

    public func resolvePractice(
        routineID: UUID,
        resolution: PracticeMigrationResolution
    ) {
        practiceMigrationResolutions[routineID] = resolution
    }

    public func resolvePracticeBlocks(
        projectID: UUID,
        resolution: PracticeBlocksMigrationResolution
    ) {
        practiceBlocksMigrationResolutions[projectID] = resolution
    }

    public func retryMigrationGate() {
        prepareMigrationGate(for: migrationRepository)
    }

    public var isMigrationBlockingSync: Bool {
        migrationGateBlocked
            || pendingMigration != nil
            || pendingPlanRevisionMigration != nil
            || pendingPracticeBlocksMigration != nil
    }

    public func clearMigrationError() {
        migrationError = nil
    }

    public func continueMigration() {
        let resolutions: [MigrationResolution] =
            migrationResolutions.map { .project($0.key, $0.value) }
            + proofMigrationResolutions.map { .proof($0.key, $0.value) }
            + practiceMigrationResolutions.map { .practice($0.key, $0.value) }
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
            migrationGateBlocked = false
            migrationResolutions = [:]
            proofMigrationResolutions = [:]
            practiceMigrationResolutions = [:]
            practiceBlocksMigrationResolutions = [:]
            pendingMigration = nil
            pendingPlanRevisionMigration = nil
            pendingPracticeBlocksMigration = nil
            rebuildViewModels(using: migrationRepository)
            // B2 has no user-choice prompts: once B1 is complete, map legacy
            // CoursePlan revisions to stable Learning Plan identities with a
            // deterministic backup before allowing sync to resume.
            prepareMigrationGate(for: migrationRepository)
            if case .cloud = accountCoordinator.state.mode {
                Task { [weak self] in
                    guard let self, !self.isMigrationBlockingSync else { return }
                    try? await self.viewModel.syncNow()
                }
            }
        } catch {
            migrationError = error.localizedDescription
        }
    }

    private func prepareMigrationGate(for repository: any JournalRepository) {
        do {
            if try repository.hasCompletedMigration(
                identifier: ProductConvergenceMigration.statusMigrationIdentifier
            ) {
                if try !repository.hasCompletedMigration(identifier: PlanRevisionMigration.identifier) {
                    let snapshot = try repository.snapshot()
                    let planMigration = PlanRevisionMigration()
                    let planDryRun = planMigration.dryRun(snapshot: snapshot)
                    if !planDryRun.issues.isEmpty {
                        pendingPlanRevisionMigration = planDryRun
                        pendingMigration = nil
                        pendingPracticeBlocksMigration = nil
                        migrationGateBlocked = false
                        migrationError = nil
                        return
                    }
                    let backupDirectory = documentsDirectory
                        .appendingPathComponent("LearningJournal", isDirectory: true)
                        .appendingPathComponent("Migrations", isDirectory: true)
                        .appendingPathComponent("B2", isDirectory: true)
                    _ = try planMigration.execute(
                        snapshot: snapshot,
                        repository: repository,
                        backupDirectory: backupDirectory
                    )
                    rebuildViewModels(using: repository)
                }

                if try !repository.hasCompletedMigration(identifier: PracticeBlocksMigration.identifier) {
                    let snapshot = try repository.snapshot()
                    let practiceMigration = PracticeBlocksMigration()
                    let practiceDryRun = practiceMigration.dryRun(snapshot: snapshot)
                    if !practiceDryRun.issues.isEmpty {
                        pendingPracticeBlocksMigration = practiceDryRun
                        pendingMigration = nil
                        pendingPlanRevisionMigration = nil
                        migrationGateBlocked = false
                        migrationError = nil
                        return
                    }
                    let backupDirectory = documentsDirectory
                        .appendingPathComponent("LearningJournal", isDirectory: true)
                        .appendingPathComponent("Migrations", isDirectory: true)
                        .appendingPathComponent("B3", isDirectory: true)
                    _ = try practiceMigration.execute(
                        snapshot: snapshot,
                        repository: repository,
                        backupDirectory: backupDirectory
                    )
                    rebuildViewModels(using: repository)
                }
                pendingMigration = nil
                pendingPlanRevisionMigration = nil
                pendingPracticeBlocksMigration = nil
                migrationGateBlocked = false
                migrationError = nil
                return
            }
        } catch {
            migrationGateBlocked = true
            migrationError = "Could not inspect migration state: \(error.localizedDescription)"
            pendingMigration = nil
            pendingPlanRevisionMigration = nil
            pendingPracticeBlocksMigration = nil
            return
        }

        let snapshot: JournalSnapshot
        do {
            snapshot = try repository.snapshot()
        } catch {
            migrationGateBlocked = true
            migrationError = "Could not inspect journal data: \(error.localizedDescription)"
            pendingMigration = nil
            pendingPlanRevisionMigration = nil
            pendingPracticeBlocksMigration = nil
            return
        }
        let dryRun = ProductConvergenceMigration().dryRun(snapshot: snapshot)
        guard dryRun.issues.isEmpty else {
            pendingMigration = dryRun
            pendingPlanRevisionMigration = nil
            pendingPracticeBlocksMigration = nil
            migrationGateBlocked = false
            if pendingMigration == nil { migrationError = nil }
            return
        }

        do {
            let backupDirectory = documentsDirectory
                .appendingPathComponent("LearningJournal", isDirectory: true)
                .appendingPathComponent("Migrations", isDirectory: true)
                .appendingPathComponent("B1", isDirectory: true)
            _ = try ProductConvergenceMigration().execute(
                snapshot: snapshot,
                resolutions: [],
                repository: repository,
                backupDirectory: backupDirectory
            )
            rebuildViewModels(using: repository)
            // A clean B1 still needs to establish its marker before B2/B3
            // can run. Re-enter the gate so each stage is checked and marked
            // before sync is considered safe.
            prepareMigrationGate(for: repository)
        } catch {
            migrationGateBlocked = true
            migrationError = "Could not complete the initial migration: \(error.localizedDescription)"
            pendingMigration = nil
            pendingPlanRevisionMigration = nil
            pendingPracticeBlocksMigration = nil
        }
    }

    public func continuePlanRevisionMigration(with survivors: [UUID: UUID]) {
        guard pendingPlanRevisionMigration != nil else { return }
        do {
            let snapshot = try migrationRepository.snapshot()
            let backupDirectory = documentsDirectory
                .appendingPathComponent("LearningJournal", isDirectory: true)
                .appendingPathComponent("Migrations", isDirectory: true)
                .appendingPathComponent("B2", isDirectory: true)
            _ = try PlanRevisionMigration().execute(
                snapshot: snapshot,
                repository: migrationRepository,
                backupDirectory: backupDirectory,
                activePlanSurvivors: survivors
            )
            pendingPlanRevisionMigration = nil
            pendingPracticeBlocksMigration = nil
            migrationError = nil
            migrationGateBlocked = false
            rebuildViewModels(using: migrationRepository)
            prepareMigrationGate(for: migrationRepository)
        } catch {
            migrationError = error.localizedDescription
        }
    }

    public func continuePracticeBlocksMigration(
        with resolutions: [PracticeBlocksMigrationResolution]
    ) {
        guard pendingPracticeBlocksMigration != nil else { return }
        do {
            let snapshot = try migrationRepository.snapshot()
            let backupDirectory = documentsDirectory
                .appendingPathComponent("LearningJournal", isDirectory: true)
                .appendingPathComponent("Migrations", isDirectory: true)
                .appendingPathComponent("B3", isDirectory: true)
            _ = try PracticeBlocksMigration().execute(
                snapshot: snapshot,
                repository: migrationRepository,
                backupDirectory: backupDirectory,
                resolutions: resolutions
            )
            pendingPracticeBlocksMigration = nil
            practiceBlocksMigrationResolutions = [:]
            migrationError = nil
            migrationGateBlocked = false
            rebuildViewModels(using: migrationRepository)
            prepareMigrationGate(for: migrationRepository)
            if case .cloud = accountCoordinator.state.mode {
                Task { [weak self] in
                    guard let self, !self.isMigrationBlockingSync else { return }
                    try? await self.viewModel.syncNow()
                }
            }
        } catch {
            migrationError = error.localizedDescription
        }
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
