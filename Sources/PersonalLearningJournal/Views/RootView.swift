import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// vNext root: four primary tabs — Today, Courses, Trail, and AI —
/// built by switching over `StudioExperienceContract.vNextPrimaryTabs`, so
/// the contract tests pin the real tab structure. Calendar, Proof Library,
/// Reviews, Sync & Conflicts, AI Settings, Export/Import, and App Lock stay
/// reachable from the top-right menu on both tabs.
public struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var calendarViewModel: CalendarViewModel
    private let practiceLifecycle: PracticeTimerLifecycleCoordinator
    private let practiceAlert = PracticeTimerAlertCoordinator()
    private let calendarEnabled: Bool

    @State private var showingSyncSettings = false
    @State private var showingAISettings = false
    @State private var showingAppLock = false
    @State private var onboardingCourseProject: Project?

    public init(
        viewModel: JournalViewModel,
        calendarViewModel: CalendarViewModel,
        calendarEnabled: Bool = true
    ) {
        self.viewModel = viewModel
        self.calendarViewModel = calendarViewModel
        self.calendarEnabled = calendarEnabled
        practiceLifecycle = PracticeTimerLifecycleCoordinator(
            runtime: viewModel.practiceTimer,
            feedback: { Self.sendPracticeTargetFeedback() },
            targetReached: { _ = try? viewModel.finishCountdownAndSavePractice() }
        )
    }

    public var body: some View {
        Group {
            if viewModel.shouldShowMainTabs {
                TabView {
                    ForEach(StudioExperienceContract.vNextPrimaryTabs, id: \.self) { tab in
                        rootTab(tab)
                    }
                }
                .environmentObject(calendarViewModel)
                .tint(StudioTheme.accent)
            } else {
                OnboardingView(viewModel: viewModel) { project in
                    onboardingCourseProject = project
                }
            }
        }
        .background {
            PracticeTimerLifecycleView(
                coordinator: practiceLifecycle,
                alertCoordinator: practiceAlert
            )
        }
        .sheet(isPresented: $showingSyncSettings) {
            SyncSettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingAISettings) {
            AIReviewSettingsView()
        }
        .sheet(isPresented: $showingAppLock) {
            AppLockSettingsView()
        }
        // Presented at the root so it survives the onboarding → main tabs
        // transition: creating the course shell flips `shouldShowMainTabs`.
        .sheet(item: $onboardingCourseProject) { project in
            CoursePlanWizardView(viewModel: viewModel, project: project)
                .environmentObject(calendarViewModel)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.applicationDidBecomeActive() }
        }
    }

    @ViewBuilder
    private func rootTab(_ tab: StudioPrimaryTab) -> some View {
        switch tab {
        case .today:
            NavigationStack {
                VNextTodayView(viewModel: viewModel)
                    .toolbar { ToolbarItem(placement: .primaryAction) { rootMenu } }
            }
            .tabItem { Label("vnext.today.title", systemImage: "play.circle") }
        case .courses:
            NavigationStack {
                CoursesView(viewModel: viewModel)
                    .toolbar { ToolbarItem(placement: .primaryAction) { rootMenu } }
            }
            .tabItem { Label("nav.courses", systemImage: "book.closed") }
        case .trail:
            NavigationStack {
                ProjectTrailView(viewModel: viewModel)
                    .toolbar { ToolbarItem(placement: .primaryAction) { rootMenu } }
            }
            .tabItem { Label("nav.trail", systemImage: "chart.xyaxis.line") }
        case .coach:
            NavigationStack {
                LearningCoachView(viewModel: viewModel)
                    .toolbar { ToolbarItem(placement: .primaryAction) { rootMenu } }
            }
            .tabItem { Label("nav.coach", systemImage: "sparkles") }
        case .projects, .calendar, .library:
            // Unreachable: vNextPrimaryTabs uses the four current surfaces. The
            // legacy cases remain on StudioPrimaryTab until the legacy tab
            // model is fully removed.
            EmptyView()
        }
    }

    /// The spec 6.1 top-right menu: every secondary capability, none of them
    /// competing with the Today → study → record loop for primary navigation.
    private var rootMenu: some View {
        Menu {
            if calendarEnabled {
                NavigationLink {
                    StudyCalendarView(viewModel: calendarViewModel)
                } label: {
                    Label("root.menu.calendar", systemImage: "calendar")
                }
            }
            NavigationLink {
                LibraryView(viewModel: viewModel)
            } label: {
                Label("root.menu.library", systemImage: "paperclip")
            }
            NavigationLink {
                LibraryView(viewModel: viewModel, initialFilter: .reviews)
            } label: {
                Label("root.menu.reviews", systemImage: "doc.text.magnifyingglass")
            }
            Divider()
            Button {
                showingSyncSettings = true
            } label: {
                Label("root.menu.sync", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
            Button {
                showingAISettings = true
            } label: {
                Label("root.menu.ai_settings", systemImage: "slider.horizontal.3")
            }
            NavigationLink {
                LibraryView(viewModel: viewModel, initialFilter: .exports)
            } label: {
                Label("root.menu.export", systemImage: "square.and.arrow.up")
            }
            Button {
                showingAppLock = true
            } label: {
                Label("root.menu.app_lock", systemImage: "lock")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel(Text("root.menu.label"))
    }

    private static func sendPracticeTargetFeedback() {
        #if canImport(AudioToolbox)
        AudioServicesPlaySystemSound(1005)
        #endif
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        #endif
    }
}

/// App Lock settings entry (spec 6.1 menu). The toggle mirrors the Privacy
/// section of Sync Settings; both write through the shared controller.
private struct AppLockSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLock = AppLockController.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("privacy.app_lock", isOn: Binding(
                        get: { appLock.isEnabled },
                        set: { appLock.setEnabled($0) }
                    ))
                    Text("privacy.app_lock_detail")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(Text("root.menu.app_lock"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("app_lock.done")
                    }
                }
            }
        }
    }
}

private struct PracticeTimerLifecycleView: View {
    @Environment(\.scenePhase) private var scenePhase
    let coordinator: PracticeTimerLifecycleCoordinator
    let alertCoordinator: PracticeTimerAlertCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Color.clear
                .frame(width: 0, height: 0)
                .onChange(of: timeline.date, initial: true) { _, _ in
                    guard scenePhase == .active else { return }
                    coordinator.refresh(deliverFeedback: true)
                    Task { await reconcileAlert() }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            coordinator.refresh(deliverFeedback: phase == .active)
            Task { await reconcileAlert() }
        }
        .accessibilityHidden(true)
    }

    private func reconcileAlert() async {
        await alertCoordinator.reconcile(
            snapshot: coordinatorSnapshot,
            now: coordinator.lastRefreshDate
        )
    }

    private var coordinatorSnapshot: PracticeTimerSnapshot {
        coordinator.snapshot
    }
}
