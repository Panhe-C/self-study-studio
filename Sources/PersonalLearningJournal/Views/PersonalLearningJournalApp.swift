import SwiftUI

public struct PersonalLearningJournalApp: App {
    @StateObject private var session: JournalApplicationSession

    public init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        _session = StateObject(
            wrappedValue: JournalApplicationSession(documentsDirectory: documents)
        )
    }

    public var body: some Scene {
        WindowGroup {
            RootView(viewModel: session.viewModel)
                .id(ObjectIdentifier(session.viewModel))
        }
    }
}
