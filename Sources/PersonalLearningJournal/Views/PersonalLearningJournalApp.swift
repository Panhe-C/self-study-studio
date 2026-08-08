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
                            },
                            onProofResolution: { proofID, resolution in
                                session.resolveProof(proofID: proofID, resolution: resolution)
                            },
                            onPracticeResolution: { routineID, resolution in
                                session.resolvePractice(routineID: routineID, resolution: resolution)
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
                } else if let pendingPlanMigration = session.pendingPlanRevisionMigration {
                    NavigationStack {
                        PlanRevisionMigrationReviewView(
                            snapshot: session.viewModel.snapshot,
                            dryRun: pendingPlanMigration,
                            onContinue: { survivors in
                                session.continuePlanRevisionMigration(with: survivors)
                            }
                        )
                    }
                    .alert(
                        "Learning Plan migration could not continue",
                        isPresented: Binding(
                            get: { session.migrationError != nil },
                            set: { if !$0 { session.clearMigrationError() } }
                        )
                    ) {
                        Button("OK") { session.clearMigrationError() }
                    } message: {
                        Text(session.migrationError ?? "")
                    }
                } else if let pendingPracticeMigration = session.pendingPracticeBlocksMigration {
                    NavigationStack {
                        PracticeBlocksMigrationReviewView(
                            snapshot: session.viewModel.snapshot,
                            dryRun: pendingPracticeMigration,
                            onContinue: { resolutions in
                                session.continuePracticeBlocksMigration(with: resolutions)
                            },
                            onResolution: { projectID, resolution in
                                session.resolvePracticeBlocks(
                                    projectID: projectID,
                                    resolution: resolution
                                )
                            }
                        )
                    }
                    .alert(
                        "Practice blocks migration could not continue",
                        isPresented: Binding(
                            get: { session.migrationError != nil },
                            set: { if !$0 { session.clearMigrationError() } }
                        )
                    ) {
                        Button("OK") { session.clearMigrationError() }
                    } message: {
                        Text(session.migrationError ?? "")
                    }
                } else if session.migrationGateBlocked {
                    NavigationStack {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.orange)
                            Text("Migration is paused until the journal can be checked safely.")
                                .multilineTextAlignment(.center)
                            Button("Retry migration check") {
                                session.retryMigrationGate()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(24)
                        .navigationTitle("Safe Migration")
                    }
                    .alert(
                        "Migration check failed",
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
