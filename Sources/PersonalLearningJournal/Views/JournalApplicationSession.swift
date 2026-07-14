import Combine
import Foundation

@MainActor
public final class JournalApplicationSession: ObservableObject {
    @Published public private(set) var viewModel: JournalViewModel
    @Published public private(set) var calendarViewModel: CalendarViewModel

    private let documentsDirectory: URL
    private let accountCoordinator: CloudAccountCoordinator
    private let accountProvider: any CloudAccountProviding
    private let practiceTimer: PracticeTimerRuntime

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
        self.calendarViewModel = CalendarViewModel(
            repository: repository,
            calendarClient: EventKitCalendarClient()
        )
        self.viewModel = Self.makeViewModel(
            repository: repository,
            accountCoordinator: accountCoordinator,
            practiceTimer: practiceTimer
        )

        Task { [weak self] in
            await self?.refreshAccount()
        }
    }

    public func refreshAccount() async {
        await accountCoordinator.refresh(using: accountProvider)
        guard let repository = accountCoordinator.activeRepository else { return }
        calendarViewModel = CalendarViewModel(
            repository: repository,
            calendarClient: EventKitCalendarClient()
        )
        viewModel = Self.makeViewModel(
            repository: repository,
            accountCoordinator: accountCoordinator,
            practiceTimer: practiceTimer
        )
        if case .cloud = accountCoordinator.state.mode {
            await viewModel.refreshSyncSummary()
            try? await viewModel.syncNow()
        } else {
            await viewModel.refreshSyncSummary()
        }
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
