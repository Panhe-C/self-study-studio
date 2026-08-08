import SwiftUI

public struct PersonalLearningJournalApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: JournalApplicationSession
    @StateObject private var appLock = AppLockController.shared

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
            Group {
                if let pendingMigration = session.pendingMigration {
                    NavigationStack {
                        MigrationReviewView(
                            dryRun: pendingMigration,
                            onContinue: { session.continueMigration() },
                            onStatusResolution: { projectID, resolution in
                                session.resolveArchivedProject(
                                    projectID: projectID,
                                    resolution: resolution
                                )
                            }
                        )
                    }
                    .alert(
                        "Migration could not continue",
                        isPresented: Binding(
                            get: { session.migrationError != nil },
                            set: { if !$0 { session.clearMigrationError() } }
                        )
                    ) {
                        Button("OK") { session.clearMigrationError() }
                    } message: {
                        Text(session.migrationError ?? "")
                    }
                } else {
                    RootView(
                        viewModel: session.viewModel,
                        calendarViewModel: session.calendarViewModel
                    )
                    .id(ObjectIdentifier(session.viewModel))
                }
            }
            .overlay {
                if appLock.showsPrivacyCover || !appLock.isUnlocked {
                    ZStack {
                        Color(red: 0.96, green: 0.95, blue: 0.92).ignoresSafeArea()
                        VStack(spacing: 14) {
                            Image(systemName: "lock.shield.fill").font(.largeTitle)
                            Text("Self Study Studio").font(.headline)
                            Button("Unlock") { Task { _ = await appLock.unlock() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: Task { await appLock.applicationDidBecomeActive() }
                case .background, .inactive: appLock.applicationDidEnterBackground()
                @unknown default: appLock.applicationDidEnterBackground()
                }
            }
        }
    }
}
