import SwiftUI

@main
struct SelfStudyStudioApp: App {
    @StateObject private var session: JournalApplicationSession

    init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        _session = StateObject(
            wrappedValue: JournalApplicationSession(documentsDirectory: documents)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                viewModel: session.viewModel,
                calendarViewModel: session.calendarViewModel
            )
            .id(ObjectIdentifier(session.viewModel))
        }
    }
}
