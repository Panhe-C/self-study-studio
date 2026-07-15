import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var calendarViewModel: CalendarViewModel
    private let practiceLifecycle: PracticeTimerLifecycleCoordinator
    private let calendarEnabled: Bool

    public init(
        viewModel: JournalViewModel,
        calendarViewModel: CalendarViewModel,
        calendarEnabled: Bool = true
    ) {
        self.viewModel = viewModel
        self.calendarViewModel = calendarViewModel
        self.calendarEnabled = calendarEnabled
        practiceLifecycle = PracticeTimerLifecycleCoordinator(runtime: viewModel.practiceTimer) {
            Self.sendPracticeTargetHaptic()
        }
    }

    public var body: some View {
        Group {
            if viewModel.shouldShowMainTabs {
                TabView {
                    NavigationStack {
                        TodayView(viewModel: viewModel)
                    }
                    .tabItem { Label("nav.today", systemImage: "play.circle") }

                    NavigationStack {
                        ProjectsView(viewModel: viewModel)
                    }
                    .tabItem { Label("nav.projects", systemImage: "folder") }

                    if calendarEnabled {
                        NavigationStack {
                            StudyCalendarView(viewModel: calendarViewModel)
                        }
                        .tabItem { Label("nav.calendar", systemImage: "calendar") }
                    }

                    NavigationStack {
                        LibraryView(viewModel: viewModel)
                    }
                    .tabItem { Label("nav.library", systemImage: "paperclip") }
                }
                .environmentObject(calendarViewModel)
                .tint(StudioTheme.accent)
            } else {
                OnboardingView(viewModel: viewModel)
            }
        }
        .background {
            PracticeTimerLifecycleView(coordinator: practiceLifecycle)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.applicationDidBecomeActive() }
        }
    }

    private static func sendPracticeTargetHaptic() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        #endif
    }
}

private struct PracticeTimerLifecycleView: View {
    @Environment(\.scenePhase) private var scenePhase
    let coordinator: PracticeTimerLifecycleCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Color.clear
                .frame(width: 0, height: 0)
                .onChange(of: timeline.date, initial: true) { _, _ in
                    guard scenePhase == .active else { return }
                    coordinator.refresh(deliverFeedback: true)
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            coordinator.refresh(deliverFeedback: phase == .active)
        }
        .accessibilityHidden(true)
    }
}
