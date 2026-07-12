import SwiftUI

public struct RootView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var calendarViewModel: CalendarViewModel

    public init(viewModel: JournalViewModel, calendarViewModel: CalendarViewModel) {
        self.viewModel = viewModel
        self.calendarViewModel = calendarViewModel
    }

    public var body: some View {
        Group {
            if viewModel.hasCompletedOnboarding {
                TabView {
                    NavigationStack {
                        TodayView(viewModel: viewModel)
                    }
                    .tabItem { Label("Today", systemImage: "play.circle") }

                    NavigationStack {
                        ProjectsView(viewModel: viewModel)
                    }
                    .tabItem { Label("Projects", systemImage: "folder") }

                    NavigationStack {
                        StudyCalendarView(viewModel: calendarViewModel)
                    }
                    .tabItem { Label("Calendar", systemImage: "calendar") }

                    NavigationStack {
                        LibraryView(viewModel: viewModel)
                    }
                    .tabItem { Label("Library", systemImage: "paperclip") }
                }
                .environmentObject(calendarViewModel)
            } else {
                OnboardingView(viewModel: viewModel)
            }
        }
    }
}
