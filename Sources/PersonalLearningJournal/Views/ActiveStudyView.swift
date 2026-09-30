import SwiftUI

/// Container for the guided study flow (spec 5.1, 9): active study →
/// completion check → record draft → confirmed. Renders whichever step the
/// controller's `StudyFlowViewState` points at, and never writes to the
/// journal itself — ending the timer only writes the pending capture.
public struct StudyFlowSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: JournalViewModel
    @StateObject private var controller: StudyFlowController
    private let startProject: Project?
    private let startPlannedSession: PlannedSession?
    private let reopeningCapture: PendingStudyCapture?
    @State private var showingDiscardConfirmation = false

    /// Starts a fresh capture for a planned session (or a project timer).
    public init(
        viewModel: JournalViewModel,
        project: Project,
        plannedSession: PlannedSession? = nil
    ) {
        self.viewModel = viewModel
        self.startProject = project
        self.startPlannedSession = plannedSession
        self.reopeningCapture = nil
        _controller = StateObject(wrappedValue: viewModel.makeStudyFlowController())
    }

    /// Reopens a persisted pending capture (saved for later, awaiting check
    /// or confirmation, or a recovered timer).
    public init(
        viewModel: JournalViewModel,
        reopening capture: PendingStudyCapture
    ) {
        self.viewModel = viewModel
        self.startProject = nil
        self.startPlannedSession = nil
        self.reopeningCapture = capture
        _controller = StateObject(wrappedValue: viewModel.makeStudyFlowController())
    }

    private var project: Project? {
        if let startProject { return startProject }
        guard let projectID = controller.state.projectID ?? reopeningCapture?.projectID else {
            return nil
        }
        return viewModel.projects.first { $0.id == projectID }
    }

    private var plannedSession: PlannedSession? {
        if let startPlannedSession { return startPlannedSession }
        guard let plannedID = controller.state.plannedSessionID ?? reopeningCapture?.plannedSessionID else {
            return nil
        }
        return viewModel.plannedSessions.first { $0.id == plannedID }
    }

    private var courseURL: URL? {
        plannedSession.flatMap { session in
            viewModel.coursePlans.first { $0.id == session.planId }?.courseURL
        }
    }

    public var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        overflowMenu
                    }
                }
        }
        .interactiveDismissDisabled(controller.state.requiresExplicitExit)
        .onAppear(perform: startIfNeeded)
        .onChange(of: controller.state) { _, newState in
            if case .idle = newState {
                dismiss()
            }
        }
        .confirmationDialog(
            Text("study_flow.discard.title"),
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("study_flow.discard.confirm", role: .destructive) {
                controller.discard()
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("study_flow.discard.message")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .active, .paused:
            ActiveStudyView(
                controller: controller,
                project: project,
                plannedSession: plannedSession,
                courseURL: courseURL
            )
        case .awaitingCheck:
            CompletionCheckView(controller: controller)
        case .awaitingRecordConfirmation:
            LearningRecordDraftView(controller: controller)
        case .completed:
            confirmedContent
        case let .failed(message, _):
            failedContent(message: message)
        }
    }

    private var confirmedContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(StudioTheme.completed)
                .accessibilityHidden(true)
            Text("study_flow.confirmed.message")
                .font(.headline)
            Button {
                controller.dismiss()
            } label: {
                Text("study_flow.confirmed.back")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(StudioTheme.accent)
            .accessibilityLabel(Text("study_flow.confirmed.back"))
            Spacer()
        }
        .padding(.horizontal, StudioTheme.pageInset)
    }

    private func failedContent(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(StudioTheme.notice)
                .accessibilityHidden(true)
            Text("study_flow.error.title")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("study_flow.error.back") {
                controller.recoverFromFailure()
            }
            .buttonStyle(.borderedProminent)
            .tint(StudioTheme.accent)
            Button("action.done") {
                controller.dismiss()
            }
            Spacer()
        }
        .padding(.horizontal, StudioTheme.pageInset)
    }

    private var overflowMenu: some View {
        Menu {
            switch controller.state {
            case .active, .paused, .awaitingCheck, .awaitingRecordConfirmation:
                Button(role: .destructive) {
                    showingDiscardConfirmation = true
                } label: {
                    Label("study_flow.discard.title", systemImage: "xmark.circle")
                }
            default:
                EmptyView()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel(Text("study_flow.more_actions"))
    }

    private func startIfNeeded() {
        guard case .idle = controller.state else { return }
        if let reopeningCapture {
            controller.reopen(reopeningCapture)
        } else if let startProject {
            controller.begin(project: startProject, plannedSession: startPlannedSession)
        }
    }
}

/// The running-study screen (spec 9.1): title, recommendation reason,
/// completion criteria, materials link, timer, pause, and "结束学习".
/// Ending only enters the completion check — no Session is written here.
public struct ActiveStudyView: View {
    @ObservedObject var controller: StudyFlowController
    let project: Project?
    let plannedSession: PlannedSession?
    let courseURL: URL?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isEnding = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(
        controller: StudyFlowController,
        project: Project?,
        plannedSession: PlannedSession?,
        courseURL: URL? = nil
    ) {
        self.controller = controller
        self.project = project
        self.plannedSession = plannedSession
        self.courseURL = courseURL
    }

    private var isRunning: Bool {
        if case .active = controller.state { return true }
        return false
    }

    private var prefersVerticalLayout: Bool {
        StudyFlowViewState.prefersVerticalLayout(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioTheme.sectionSpacing) {
                activityCard
                timerCard
            }
            .padding(.horizontal, StudioTheme.pageInset)
            .padding(.bottom, 28)
        }
        .background(StudioTheme.pageBackground.ignoresSafeArea())
        .navigationTitle(Text("study_flow.active.title"))
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plannedSession?.title ?? project?.name ?? "")
                .font(.headline)
            if let project {
                Text(project.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = plannedSession?.recommendationReason, !reason.isEmpty {
                Label(reason, systemImage: "sparkle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let criteria = plannedSession?.completionCriteria, !criteria.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("study_flow.active.criteria")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(criteria, id: \.self) { criterion in
                        Label(criterion, systemImage: "circle")
                            .font(.subheadline)
                    }
                }
            }
            if let courseURL {
                Link(destination: courseURL) {
                    Label("study_flow.active.materials", systemImage: "link")
                        .font(.subheadline)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var timerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(StudioDurationFormat.clock(seconds: controller.elapsedSeconds))
                    .font(.system(.largeTitle, design: .rounded).monospacedDigit())
                    .accessibilityHidden(true)
            }
            Text("study_flow.elapsed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityValue("\(controller.elapsedSeconds / 60)")

            if prefersVerticalLayout {
                VStack(spacing: 10) {
                    pauseResumeButton
                    endButton
                }
            } else {
                HStack(spacing: 12) {
                    pauseResumeButton
                    endButton
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        // Timer ticks are driven by the visible clock; when this card is on
        // screen the controller keeps its in-memory elapsed value current.
        .onReceive(ticker) { _ in
            controller.tick()
        }
    }

    private var pauseResumeButton: some View {
        Button {
            if isRunning {
                controller.pause()
            } else {
                controller.resume()
            }
        } label: {
            Label {
                isRunning ? Text("study_flow.pause") : Text("study_flow.resume")
            } icon: {
                Image(systemName: isRunning ? "pause.circle" : "play.circle")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var endButton: some View {
        Button {
            guard !isEnding else { return }
            isEnding = true
            Task {
                await controller.end()
                isEnding = false
            }
        } label: {
            Label("study_flow.end", systemImage: "stop.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(StudioTheme.accent)
        .disabled(isEnding)
        .accessibilityLabel(Text("study_flow.end"))
    }
}
