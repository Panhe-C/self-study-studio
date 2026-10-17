import SwiftUI

@main
struct SelfStudyStudioApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: ProgressApplicationSession
    @StateObject private var appLock = AppLockController.shared

    init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        _session = StateObject(
            wrappedValue: ProgressApplicationSession(documentsDirectory: documents)
        )
    }

    var body: some Scene {
        WindowGroup {
            ProgressRootView(session: session)
                .overlay {
                    if appLock.showsPrivacyCover || !appLock.isUnlocked {
                        ZStack {
                            Color(.systemBackground).ignoresSafeArea()
                            VStack(spacing: 14) {
                                Image(systemName: "lock.shield.fill").font(.largeTitle)
                                Text("Self Study Studio").font(.headline)
                                Button("解锁") { Task { _ = await appLock.unlock() } }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        Task { await appLock.applicationDidBecomeActive() }
                    case .background, .inactive:
                        appLock.applicationDidEnterBackground()
                    @unknown default:
                        appLock.applicationDidEnterBackground()
                    }
                }
        }
    }
}
