import SwiftUI

public struct RootView: View {
    @ObservedObject private var viewModel: JournalViewModel

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
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
                        LibraryView(viewModel: viewModel)
                    }
                    .tabItem { Label("Library", systemImage: "paperclip") }
                }
            } else {
                OnboardingView(viewModel: viewModel)
            }
        }
    }
}
