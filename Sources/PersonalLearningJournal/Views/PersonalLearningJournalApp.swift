import SwiftUI

public struct PersonalLearningJournalApp: App {
    @StateObject private var viewModel: JournalViewModel

    public init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let journalService = JournalService(
            repository: Self.makeJournalRepository(documentsDirectory: documents)
        )
        let reviewProvider: any AIReviewProvider = AdaptiveAIReviewProvider()
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(
                journalService: journalService,
                provider: reviewProvider
            ),
            exportService: ExportService()
        )
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel)
        }
    }

    private static func makeJournalRepository(
        documentsDirectory: URL
    ) -> any JournalRepository {
        do {
            let journalDirectory = documentsDirectory
                .appendingPathComponent("LearningJournal", isDirectory: true)
            let repository = try RepositoryFactory.makeDefault(
                storeURL: journalDirectory
                    .appendingPathComponent("local", isDirectory: true)
                    .appendingPathComponent("journal-v2.store")
            )
            let legacyStore = try JournalStoreFactory.makeDefault(
                documentsDirectory: documentsDirectory
            )
            try RepositoryMigration().migrateIfNeeded(
                from: legacyStore,
                to: repository,
                backupDirectory: journalDirectory
            )
            return repository
        } catch {
            return InMemoryJournalRepository()
        }
    }
}
