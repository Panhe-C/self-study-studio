import SwiftUI

public struct StudyCalendarView: View {
    @ObservedObject private var viewModel: CalendarViewModel
    @State private var showingDraft = false
    @State private var isGenerating = false
    @State private var errorMessage: String?

    public init(viewModel: CalendarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            calendarContent
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink {
                    CalendarSettingsView(viewModel: viewModel)
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Calendar settings")
                .accessibilityLabel("Calendar settings")
            }
            if !viewModel.reconciliationItems.isEmpty {
                ToolbarItem(placement: .secondaryAction) {
                    NavigationLink {
                        CalendarReconciliationView(viewModel: viewModel)
                    } label: {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel("Review calendar changes")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    generateDraft()
                } label: {
                    Image(systemName: "calendar.badge.clock")
                }
                .disabled(isGenerating)
                .help("Generate schedule")
                .accessibilityLabel("Generate schedule")
            }
        }
        .task { await viewModel.refresh() }
        .sheet(isPresented: $showingDraft) {
            ScheduleDraftView(viewModel: viewModel)
        }
        .alert("Schedule unavailable", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Calendar mode", selection: modeBinding) {
                ForEach(StudyCalendarMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button { viewModel.navigatePrevious() } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous")
                Spacer()
                Button("Today") { viewModel.goToToday() }
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { viewModel.navigateNext() } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var calendarContent: some View {
        switch viewModel.mode {
        case .day:
            DayCalendarView(viewModel: viewModel)
        case .week:
            WeekCalendarView(viewModel: viewModel)
        case .month:
            MonthCalendarView(viewModel: viewModel)
        }
    }

    private var modeBinding: Binding<StudyCalendarMode> {
        Binding(
            get: { viewModel.mode },
            set: { viewModel.setMode($0) }
        )
    }

    private var title: String {
        switch viewModel.mode {
        case .day:
            viewModel.focusedDate.formatted(.dateTime.month(.abbreviated).day())
        case .week:
            "Study Week"
        case .month:
            viewModel.focusedDate.formatted(.dateTime.month(.wide).year())
        }
    }

    private func generateDraft() {
        isGenerating = true
        Task {
            defer { isGenerating = false }
            do {
                _ = try await viewModel.generateSchedule()
                showingDraft = true
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }
}
