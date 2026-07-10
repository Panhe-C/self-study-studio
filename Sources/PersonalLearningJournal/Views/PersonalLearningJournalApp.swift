import SwiftUI

public struct PersonalLearningJournalApp: App {
    @StateObject private var viewModel: JournalViewModel

    public init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let journalService = JournalService(store: Self.makeJournalStore(documentsDirectory: documents))
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

    private static func makeJournalStore(documentsDirectory: URL) -> any JournalStore {
        do {
            return try JournalStoreFactory.makeDefault(documentsDirectory: documentsDirectory)
        } catch {
            let legacyURL = documentsDirectory
                .appendingPathComponent("LearningJournal", isDirectory: true)
                .appendingPathComponent("journal.json")
            return JSONJournalStore(fileURL: legacyURL)
        }
    }
}
