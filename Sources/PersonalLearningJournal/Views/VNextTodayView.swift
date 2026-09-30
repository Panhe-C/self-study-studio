import SwiftUI

// MARK: - vNext Today projection (pure, testable)

/// The single primary action on the Up Next card. A capture holding the
/// study timer slot turns Start into Continue so the UI can never create a
/// second active capture (`PendingStudyCaptureError.activeCaptureAlreadyExists`).
public enum VNextTodayPrimaryAction: Equatable, Sendable {
    case start
    case resumeCapture(UUID)
    case startPractice(UUID)
    case resumePractice(UUID)
    case resumePracticeCompletion(UUID)
}

/// Recovery state for the device-local guided practice runtime. It is kept
/// separate from `VNextTodayRecoveryCard` because practice sessions are not
/// Learning Sessions and must never flow through PendingStudyCaptureStore.
public enum VNextTodayPracticeRecoveryKind: String, Equatable, Sendable {
    case activeTimer
    case pendingCompletion
}

public struct VNextTodayPracticeRecoveryCard: Equatable, Identifiable, Sendable {
    public let routineID: UUID
    public let title: String
    public let kind: VNextTodayPracticeRecoveryKind

    public var id: String {
        "\(kind.rawValue):\(routineID.uuidString)"
    }

    public init(
        routineID: UUID,
        title: String,
        kind: VNextTodayPracticeRecoveryKind
    ) {
        self.routineID = routineID
        self.title = title
        self.kind = kind
    }
}

/// The pending-record recovery card shown above Up Next (spec 7.1).
public struct VNextTodayRecoveryCard: Equatable, Identifiable, Sendable {
    public let capture: PendingStudyCapture
    /// Resolved planned-session title or project name; empty when the source
    /// record is gone (the view falls back to a localized placeholder).
    public let title: String

    public var id: UUID { capture.id }

    public init(capture: PendingStudyCapture, title: String) {
        self.capture = capture
        self.title = title
    }
}

/// The Up Next card model (spec 7.2): course, phase, activity, duration,
/// recommendation reason, criteria summary, one primary action.
public struct VNextTodayUpNextCard: Equatable, Sendable {
    public let item: TodayAgendaItem
    public let courseName: String?
    public let phaseName: String?
    public let recommendationReason: String?
    public let criteriaSummary: String?
    /// Resolved when the item came from a planned session; the view uses it
    /// to open the unified study flow.
    public let plannedSession: PlannedSession?
    public let primaryAction: VNextTodayPrimaryAction

    public init(
        item: TodayAgendaItem,
        courseName: String?,
        phaseName: String?,
        recommendationReason: String?,
        criteriaSummary: String?,
        plannedSession: PlannedSession?,
        primaryAction: VNextTodayPrimaryAction
    ) {
        self.item = item
        self.courseName = courseName
        self.phaseName = phaseName
        self.recommendationReason = recommendationReason
        self.criteriaSummary = criteriaSummary
        self.plannedSession = plannedSession
        self.primaryAction = primaryAction
    }
}

/// A single-line contextual banner (spec 7.1): carryover, review, sync, or
/// capacity. Never a peer-level home module.
public struct VNextTodayBanner: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case carryover
        case review
        case sync
        case capacity
    }

    public let kind: Kind
    public let count: Int

    public var id: String { kind.rawValue }

    public init(kind: Kind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

/// Everything the vNext Today screen renders, in spec order (7.1):
/// recovery card, one Up Next card, at most two alternatives, and the
/// retained full agenda behind the "view all / adjust today" entry.
public struct VNextTodayProjection: Equatable, Sendable {
    public let recoveryCard: VNextTodayRecoveryCard?
    public let practiceRecoveryCard: VNextTodayPracticeRecoveryCard?
    public let upNext: VNextTodayUpNextCard?
    public let alternatives: [TodayAgendaItem]
    public let banners: [VNextTodayBanner]
    /// The complete day agenda — including skipped items — so the
    /// "view all / adjust today" sheet can restore any choice.
    public let fullAgenda: [TodayAgendaItem]

    public init(
        recoveryCard: VNextTodayRecoveryCard?,
        practiceRecoveryCard: VNextTodayPracticeRecoveryCard? = nil,
        upNext: VNextTodayUpNextCard?,
        alternatives: [TodayAgendaItem],
        banners: [VNextTodayBanner],
        fullAgenda: [TodayAgendaItem]
    ) {
        self.recoveryCard = recoveryCard
        self.practiceRecoveryCard = practiceRecoveryCard
        self.upNext = upNext
        self.alternatives = alternatives
        self.banners = banners
        self.fullAgenda = fullAgenda
    }
}

/// Pure projection over `TodayAgendaService` output and the device-local
/// capture store. It never mutates Journal records: ordering still comes
/// from the deterministic agenda plus day-scoped overrides (spec 7.3).
public enum VNextTodayProjector {
    public static func project(
        agenda: TodayAgenda,
        pendingCaptures: [PendingStudyCapture],
        activeCapture: PendingStudyCapture?,
        snapshot: JournalSnapshot,
        pendingReviewCount: Int = 0,
        hasSyncIssue: Bool = false,
        capacityExceededCount: Int = 0,
        practiceSnapshot: PracticeTimerSnapshot? = nil,
        pendingPracticeCompletion: PracticePendingCompletionDraft? = nil
    ) -> VNextTodayProjection {
        let screen = StudioExperienceContract.firstScreen(agenda: agenda.items)

        // Pending capture takes priority over new activity (spec 7.3): the
        // timer-slot capture recovers first, then confirmations saved for
        // later or awaiting review.
        let recoveryCard = (activeCapture ?? pendingCaptures.first).map { capture in
            VNextTodayRecoveryCard(
                capture: capture,
                title: recoveryTitle(for: capture, snapshot: snapshot)
            )
        }

        // Guided captures and practice timers are independent recovery paths.
        // Keep one practice card behind the guided-flow card so Today never
        // becomes a stack of peer recovery modules, while still retaining a
        // durable entry point for either process-restored timer state.
        let practiceRecoveryCard: VNextTodayPracticeRecoveryCard? = if let pendingPracticeCompletion {
            VNextTodayPracticeRecoveryCard(
                routineID: pendingPracticeCompletion.completion.routineId,
                title: practiceTitle(
                    routineID: pendingPracticeCompletion.completion.routineId,
                    presentation: pendingPracticeCompletion.routinePresentation,
                    snapshot: snapshot
                ),
                kind: .pendingCompletion
            )
        } else if let activeRoutineID = practiceSnapshot?.activeRoutineId {
            VNextTodayPracticeRecoveryCard(
                routineID: activeRoutineID,
                title: practiceTitle(
                    routineID: activeRoutineID,
                    presentation: nil,
                    snapshot: snapshot
                ),
                kind: .activeTimer
            )
        } else {
            nil
        }

        let upNext = screen.upNext.map { item in
            makeUpNextCard(
                item: item,
                snapshot: snapshot,
                activeCapture: activeCapture,
                practiceSnapshot: practiceSnapshot,
                pendingPracticeCompletion: pendingPracticeCompletion
            )
        }

        var banners: [VNextTodayBanner] = []
        let carryoverCount = agenda.items
            .filter { $0.carryover != nil && $0.position != .skipToday }
            .count
        if carryoverCount > 0 {
            banners.append(VNextTodayBanner(kind: .carryover, count: carryoverCount))
        }
        if pendingReviewCount > 0 {
            banners.append(VNextTodayBanner(kind: .review, count: pendingReviewCount))
        }
        if hasSyncIssue {
            banners.append(VNextTodayBanner(kind: .sync, count: 0))
        }
        if capacityExceededCount > 0 {
            banners.append(VNextTodayBanner(kind: .capacity, count: capacityExceededCount))
        }

        return VNextTodayProjection(
            recoveryCard: recoveryCard,
            practiceRecoveryCard: practiceRecoveryCard,
            upNext: upNext,
            alternatives: screen.alternatives,
            banners: banners,
            fullAgenda: agenda.items
        )
    }

    private static func makeUpNextCard(
        item: TodayAgendaItem,
        snapshot: JournalSnapshot,
        activeCapture: PendingStudyCapture?,
        practiceSnapshot: PracticeTimerSnapshot?,
        pendingPracticeCompletion: PracticePendingCompletionDraft?
    ) -> VNextTodayUpNextCard {
        let project = snapshot.projects.first { $0.id == item.projectID }
        var planned: PlannedSession?
        var phaseName: String?
        if item.source == .plannedSession,
           let session = snapshot.plannedSessions.first(where: { $0.id == item.sourceID }) {
            planned = session
            phaseName = snapshot.planPhases.first { $0.id == session.phaseId }?.title
        }
        let criteria = planned?.completionCriteria ?? []
        // Practice rows use the practice runtime exclusively; learning-flow
        // rows use the capture slot and must offer Continue while it is held.
        let primaryAction: VNextTodayPrimaryAction
        if item.source == .practiceRoutine {
            primaryAction = practicePrimaryAction(
                routineID: item.sourceID,
                activeRoutineID: practiceSnapshot?.activeRoutineId,
                pendingCompletionRoutineID: pendingPracticeCompletion?.completion.routineId
            )
        } else if let activeCapture {
            primaryAction = .resumeCapture(activeCapture.id)
        } else {
            primaryAction = .start
        }
        return VNextTodayUpNextCard(
            item: item,
            courseName: project?.name,
            phaseName: phaseName,
            recommendationReason: planned?.recommendationReason,
            criteriaSummary: criteria.isEmpty ? nil : criteria.joined(separator: " · "),
            plannedSession: planned,
            primaryAction: primaryAction
        )
    }

    /// Returns the action a practice row should expose without changing its
    /// agenda position. Existing active/pending runtime state always wins, so
    /// a second routine can never be started from Today.
    public static func practicePrimaryAction(
        routineID: UUID,
        activeRoutineID: UUID?,
        pendingCompletionRoutineID: UUID?
    ) -> VNextTodayPrimaryAction {
        if let pendingCompletionRoutineID {
            return .resumePracticeCompletion(pendingCompletionRoutineID)
        }
        if let activeRoutineID {
            return .resumePractice(activeRoutineID)
        }
        return .startPractice(routineID)
    }

    private static func practiceTitle(
        routineID: UUID,
        presentation: PracticeRoutinePresentationSnapshot?,
        snapshot: JournalSnapshot
    ) -> String {
        presentation?.name
            ?? snapshot.practiceRoutines.first(where: { $0.id == routineID })?.name
            ?? ""
    }

    private static func recoveryTitle(
        for capture: PendingStudyCapture,
        snapshot: JournalSnapshot
    ) -> String {
        if let plannedID = capture.plannedSessionID,
           let planned = snapshot.plannedSessions.first(where: { $0.id == plannedID }) {
            return planned.title
        }
        return snapshot.projects.first { $0.id == capture.projectID }?.name ?? ""
    }
}

// MARK: - vNext Today view

/// The vNext Today screen (spec 7). Renders only the projection in spec
/// order: recovery card, one Up Next card, at most two alternatives, and a
/// low-weight "view all / adjust today" entry. Drop-in replacement for
/// `TodayView`; RootView migrates in Task 12.
public struct VNextTodayView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var practiceTimer: PracticeTimerRuntime
    @State private var startingContext: PlannedSessionContext?
    @State private var startingProject: Project?
    @State private var startingPractice: PracticeRoutine?
    @State private var reopeningCapture: PendingStudyCapture?
    @State private var showingFullAgenda = false
    @State private var selectedPracticeProjectID: UUID?
    @State private var practiceMode: PracticeTimerMode = .countUp
    @State private var practiceCountdownMinutes = 25
    @State private var practiceToStartAfterAgenda: UUID?
    @State private var practiceActionError: String?
    @Namespace private var practiceSelectionNamespace
    @Namespace private var practiceTimerZoomNamespace
    @State private var practiceZoomSourceID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
        _practiceTimer = ObservedObject(wrappedValue: viewModel.practiceTimer)
    }

    private var projection: VNextTodayProjection {
        viewModel.vNextTodayProjection(now: practiceTimer.lastRefreshDate)
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StudioTheme.sectionSpacing) {
                recoveryArea()
                bannerRows
                skillPracticeShelf
                if let upNext = projection.upNext {
                    upNextCard(upNext)
                } else {
                    ContentUnavailableView(
                        String(localized: "vnext.today.empty.title"),
                        systemImage: "checkmark.circle",
                        description: Text("vnext.today.empty.detail")
                    )
                    .frame(maxWidth: .infinity)
                }
                alternativeRows
                viewAllEntry
            }
            .padding(.horizontal, StudioTheme.pageInset)
            .padding(.bottom, 28)
        }
        .background(StudioTheme.pageBackground.ignoresSafeArea())
        .navigationTitle(Text("vnext.today.title"))
        .task {
            await viewModel.refreshSyncSummary()
        }
        .sheet(item: $startingContext) { context in
            StudyFlowSheet(viewModel: viewModel, project: context.project, plannedSession: context.session)
        }
        .sheet(item: $startingProject) { project in
            StudyFlowSheet(viewModel: viewModel, project: project)
        }
        .sheet(item: $startingPractice) { routine in
            PracticeTimerView(
                viewModel: viewModel,
                routine: routine,
                zoomSourceID: practiceZoomSourceID,
                zoomNamespace: practiceTimerZoomNamespace
            )
        }
        .sheet(item: $reopeningCapture) { capture in
            StudyFlowSheet(viewModel: viewModel, reopening: capture)
        }
        // Deep link (notification tap): reopen the capture at its own step.
        // The request is consumed so re-appearing views don't re-present.
        .onChange(of: viewModel.requestedCaptureReopen) { _, capture in
            guard let capture else { return }
            viewModel.requestedCaptureReopen = nil
            reopeningCapture = capture
        }
        .sheet(
            isPresented: $showingFullAgenda,
            onDismiss: {
                guard let routineID = practiceToStartAfterAgenda else { return }
                practiceToStartAfterAgenda = nil
                startPracticeFromAgenda(routineID)
            }
        ) {
            NavigationStack {
                VNextTodayAgendaSheet(
                    agenda: projection.fullAgenda,
                    onSelectPosition: { position, item in
                        setAgendaPosition(position, for: item)
                    },
                    onStartPractice: { item in
                        practiceToStartAfterAgenda = item.sourceID
                        showingFullAgenda = false
                    },
                    practiceActionTitle: { routineID in
                        practiceActionTitle(for: routineID)
                    },
                    onClearOverride: { item in
                        viewModel.clearTodayAgendaOverride(
                            day: practiceTimer.lastRefreshDate,
                            source: item.source,
                            sourceID: item.sourceID
                        )
                    }
                )
            }
        }
        .alert("vnext.today.practice.error_title", isPresented: practiceActionErrorPresented) {
            Button("vnext.today.practice.error_dismiss") { practiceActionError = nil }
        } message: {
            Text(practiceActionError ?? "")
        }
        .onAppear(perform: prepareInlinePractice)
    }

    // MARK: Recovery area

    /// Guided captures and practice timers can coexist because they use
    /// separate persistence/runtime concepts. Keep guided recovery visually
    /// primary, but place practice recovery in the same bounded area so an
    /// archived/non-today routine never loses its only resume affordance.
    @ViewBuilder
    private func recoveryArea() -> some View {
        if let guided = projection.recoveryCard,
           let practice = unlistedPracticeRecoveryCard {
            VStack(alignment: .leading, spacing: 0) {
                recoveryRow(guided)
                Divider()
                    .padding(.vertical, 4)
                compactPracticeRecoveryRow(practice)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        } else if let guided = projection.recoveryCard {
            recoveryCard(guided)
        } else if let practice = unlistedPracticeRecoveryCard {
            practiceRecoveryCard(practice)
        } else {
            EmptyView()
        }
    }

    private var unlistedPracticeRecoveryCard: VNextTodayPracticeRecoveryCard? {
        guard let recovery = projection.practiceRecoveryCard,
              activePracticeCard?.id != recovery.routineID else {
            return nil
        }
        return recovery
    }

    // MARK: Skill practice

    /// The complete everyday Practice interaction lives on Today. Selecting a
    /// project, choosing the timer and starting it never opens a setup sheet.
    private var skillPracticeShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("vnext.today.practice.shelf.title")
                    .font(.headline)
                Text("vnext.today.practice.shelf.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let activePracticeCard {
                quickPracticeRow(activePracticeCard)
                    .transition(.opacity)
            } else if practiceProjects.isEmpty {
                ContentUnavailableView(
                    String(localized: "vnext.today.practice.setup.no_projects"),
                    systemImage: "folder.badge.plus",
                    description: Text("vnext.today.practice.setup.no_projects_hint")
                )
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            } else {
                inlinePracticeLauncher
                    .transition(.opacity)
            }
        }
        // Crossfade the shelf between launcher and live practice row.
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: activePracticeCard?.id)
    }

    private var inlinePracticeLauncher: some View {
        VStack(alignment: .leading, spacing: 14) {
            projectStrip

            Picker("vnext.today.practice.setup.mode", selection: $practiceMode) {
                ForEach(PracticeTimerMode.allCases, id: \.self) { mode in
                    Text(practiceModeTitle(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if practiceMode == .countdown {
                VStack(spacing: 6) {
                    HStack {
                        Text("vnext.today.practice.setup.duration")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(
                            String(
                                format: String(localized: "vnext.today.practice.setup.minutes"),
                                practiceCountdownMinutes
                            )
                        )
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(StudioTheme.accent)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: practiceCountdownMinutes)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(practiceCountdownMinutes) },
                            set: { practiceCountdownMinutes = Int($0.rounded()) }
                        ),
                        in: 1...180,
                        step: 1
                    )
                    .tint(StudioTheme.accent)
                    .accessibilityValue(
                        Text(
                            String(
                                format: String(localized: "vnext.today.practice.setup.minutes"),
                                practiceCountdownMinutes
                            )
                        )
                    )
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top))
                )
            }

            Button(action: startInlinePractice) {
                Label("vnext.today.practice.setup.start", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(ProminentPressButtonStyle(reduceMotion: reduceMotion, tint: effectivePracticeTint))
            .disabled(effectivePracticeProjectID == nil)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .animation(.smooth(duration: 0.24), value: practiceMode)
    }

    private var projectStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(practiceProjects) { project in
                    let isSelected = project.id == effectivePracticeProjectID
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                            selectedPracticeProjectID = project.id
                        }
                    } label: {
                        Label(project.name, systemImage: "folder")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(StudioTheme.accent)
                                        .matchedGeometryEffect(
                                            id: "practice-project-selection",
                                            in: practiceSelectionNamespace
                                        )
                                } else {
                                    Capsule()
                                        .fill(StudioTheme.mutedSurface)
                                }
                            }
                            .animation(
                                reduceMotion ? nil : .smooth(duration: 0.18),
                                value: isSelected
                            )
                    }
                    .buttonStyle(PressFeedbackButtonStyle(reduceMotion: reduceMotion))
                    .id(project.id)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .accessibilityLabel(Text("vnext.today.practice.setup.project"))
    }

    private var practiceProjects: [Project] {
        viewModel.projects
            .filter { $0.deletedAt == nil && !$0.isTrashed }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var effectivePracticeProjectID: UUID? {
        if let selectedPracticeProjectID,
           practiceProjects.contains(where: { $0.id == selectedPracticeProjectID }) {
            return selectedPracticeProjectID
        }
        return practiceProjects.first?.id
    }

    /// The color of the routine the launcher would start, so the Start button
    /// and the timer screen it leads into share one color. Mirrors the
    /// routine resolution in `startSimplePractice` (default `.teal`).
    private var effectivePracticeTint: Color {
        guard let projectID = effectivePracticeProjectID,
              let routine = viewModel.snapshot.operationalPracticeRoutines.first(where: {
                  $0.projectId == projectID && !$0.isArchived && $0.deletedAt == nil
              }) else {
            return StudioTheme.practiceColor(.teal)
        }
        return StudioTheme.practiceColor(routine.color)
    }

    private var quickPracticeCards: [StudioPracticeCard] {
        viewModel.practiceCards(
            now: practiceTimer.lastRefreshDate,
            scheduledOnly: false
        )
    }

    private var activePracticeCard: StudioPracticeCard? {
        let routineID = practiceTimer.pendingCompletion?.completion.routineId
            ?? practiceTimer.snapshot.activeRoutineId
        guard let routineID else { return nil }
        return quickPracticeCards.first { $0.id == routineID }
    }

    private func quickPracticeRow(_ card: StudioPracticeCard) -> some View {
        let color = StudioTheme.practiceColor(card.routine.color)
        let pending = practiceTimer.pendingCompletion?.completion.routineId == card.id
        let total = StudioDurationFormat.compact(seconds: card.statistics.allTimeActiveSeconds)
        let projectName = practiceProjectName(for: card.routine)

        return HStack(spacing: 12) {
            Button {
                openPracticeRoutine(card.id, zoomSourceID: "practice-zoom-row")
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: card.routine.symbolName)
                        .font(.headline)
                        .foregroundStyle(color)
                        .frame(width: 44, height: 44)
                        .background(color.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(projectName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if card.isActiveTimer {
                            Text(
                                practiceDetail(
                                    routineName: card.routine.name,
                                    projectName: projectName,
                                    value: activePracticeTimeLabel
                                )
                            )
                                .font(.subheadline.monospacedDigit().weight(.medium))
                                .foregroundStyle(color)
                                .contentTransition(.numericText())
                        } else if pending {
                            Text(
                                practiceDetail(
                                    routineName: card.routine.name,
                                    projectName: projectName,
                                    value: String(localized: "vnext.today.practice.shelf.pending")
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(color)
                        } else {
                            Text(
                                practiceDetail(
                                    routineName: card.routine.name,
                                    projectName: projectName,
                                    value: String(
                                        format: String(localized: "vnext.today.practice.shelf.total"),
                                        total
                                    )
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if card.isActiveTimer {
                Button {
                    if practiceTimer.snapshot.isRunning {
                        practiceTimer.pause()
                    } else {
                        practiceTimer.resume()
                    }
                } label: {
                    Image(systemName: practiceTimer.snapshot.isRunning ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(color)
                .accessibilityLabel(
                    practiceTimer.snapshot.isRunning
                        ? Text("vnext.today.practice.pause")
                        : Text("vnext.today.practice.resume")
                )

                Button {
                    quickFinishPractice(card.routine)
                } label: {
                    Image(systemName: "checkmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(color)
                .accessibilityLabel(Text("vnext.today.practice.finish"))
            } else {
                Button {
                    openPracticeRoutine(card.id, zoomSourceID: "practice-zoom-row")
                } label: {
                    Image(systemName: pending ? "arrow.right" : "play.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(color)
                .accessibilityLabel(
                    pending
                        ? Text("vnext.today.practice.continue")
                        : Text("vnext.today.practice.start")
                )
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .studioZoomSource(id: "practice-zoom-row", namespace: practiceTimerZoomNamespace)
    }

    private func practiceProjectName(for routine: PracticeRoutine) -> String {
        guard let projectID = routine.projectId,
              let project = viewModel.projects.first(where: {
                  $0.id == projectID && $0.deletedAt == nil && !$0.isTrashed
              }) else {
            return String(localized: "vnext.today.practice.project_unavailable")
        }
        return project.name
    }

    private func practiceDetail(
        routineName: String,
        projectName: String,
        value: String
    ) -> String {
        if routineName.localizedCaseInsensitiveCompare(projectName) == .orderedSame {
            return value
        }
        return "\(routineName) · \(value)"
    }

    private var activePracticeTimeLabel: String {
        let snapshot = practiceTimer.snapshot
        if snapshot.mode == .countdown {
            let remaining = max(0, snapshot.targetSeconds - snapshot.activeElapsedSeconds)
            return String(
                format: String(localized: "vnext.today.practice.remaining"),
                StudioDurationFormat.clock(seconds: remaining)
            )
        }
        return String(
            format: String(localized: "vnext.today.practice.elapsed"),
            StudioDurationFormat.clock(seconds: snapshot.activeElapsedSeconds)
        )
    }

    private func recoveryCard(_ card: VNextTodayRecoveryCard) -> some View {
        recoveryRow(card)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func recoveryRow(_ card: VNextTodayRecoveryCard) -> some View {
        Button {
            reopeningCapture = card.capture
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "vnext.today.recovery.title"), systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.notice)
                Text(card.title.isEmpty ? String(localized: "study_flow.pending.unknown") : card.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack {
                    Text(StudyFlowCopy.pendingStageTitle(card.capture.stage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(String(localized: "vnext.today.continue"), systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudioTheme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(card.title), \(StudyFlowCopy.pendingStageTitle(card.capture.stage))"
        )
        .frame(minHeight: 44)
    }

    private func practiceRecoveryCard(
        _ card: VNextTodayPracticeRecoveryCard
    ) -> some View {
        practiceRecoveryContent(card)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func practiceRecoveryContent(
        _ card: VNextTodayPracticeRecoveryCard
    ) -> some View {
        Button {
            openPracticeRoutine(card.routineID, zoomSourceID: "practice-zoom-recovery")
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    String(localized: "vnext.today.practice.recovery.title"),
                    systemImage: card.kind == .pendingCompletion
                        ? "checkmark.circle.fill"
                        : "timer"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.accent)
                Text(
                    card.title.isEmpty
                        ? String(localized: "vnext.today.practice.unknown")
                        : card.title
                )
                .font(.headline)
                HStack {
                    Text(practiceRecoveryStatus(for: card))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(
                        String(localized: "vnext.today.practice.continue"),
                        systemImage: "play.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(practiceRecoveryAccessibilityLabel(for: card))
        .frame(minHeight: 44)
    }

    private func compactPracticeRecoveryRow(
        _ card: VNextTodayPracticeRecoveryCard
    ) -> some View {
        Button {
            openPracticeRoutine(card.routineID, zoomSourceID: "practice-zoom-recovery")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: card.kind == .pendingCompletion ? "checkmark.circle.fill" : "timer")
                    .foregroundStyle(StudioTheme.accent)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        card.title.isEmpty
                            ? String(localized: "vnext.today.practice.unknown")
                            : card.title
                    )
                    .font(.subheadline.weight(.medium))
                    Text(practiceRecoveryStatus(for: card))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Label(
                    String(localized: "vnext.today.practice.continue"),
                    systemImage: "play.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(practiceRecoveryAccessibilityLabel(for: card))
        .frame(minHeight: 44)
    }

    private func practiceRecoveryStatus(
        for card: VNextTodayPracticeRecoveryCard
    ) -> String {
        String(
            localized: card.kind == .pendingCompletion
                ? "vnext.today.practice.recovery.pending"
                : "vnext.today.practice.recovery.active"
        )
    }

    private func practiceRecoveryAccessibilityLabel(
        for card: VNextTodayPracticeRecoveryCard
    ) -> String {
        String(
            format: String(localized: "vnext.today.practice.recovery.accessibility"),
            card.title.isEmpty
                ? String(localized: "vnext.today.practice.unknown")
                : card.title
        )
    }

    // MARK: Banners

    @ViewBuilder
    private var bannerRows: some View {
        ForEach(projection.banners) { banner in
            StudioNoticeRow(title: bannerTitle(banner), icon: bannerIcon(banner))
        }
    }

    private func bannerTitle(_ banner: VNextTodayBanner) -> String {
        switch banner.kind {
        case .carryover:
            String(format: String(localized: "vnext.today.banner.carryover"), banner.count)
        case .review:
            String(format: String(localized: "vnext.today.banner.review"), banner.count)
        case .sync:
            String(localized: "vnext.today.banner.sync")
        case .capacity:
            String(format: String(localized: "vnext.today.banner.capacity"), banner.count)
        }
    }

    private func bannerIcon(_ banner: VNextTodayBanner) -> String {
        switch banner.kind {
        case .carryover: "arrow.uturn.forward.circle.fill"
        case .review: "doc.text.magnifyingglass"
        case .sync: "exclamationmark.icloud.fill"
        case .capacity: "calendar.badge.exclamationmark"
        }
    }

    // MARK: Up Next card

    private func upNextCard(_ card: VNextTodayUpNextCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(String(localized: "vnext.today.up_next"), systemImage: "sparkle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.accent)
                Spacer(minLength: 8)
                upNextMenu(card)
            }
            Text(card.item.title)
                .font(.headline)
            Text(subtitle(for: card))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let reason = card.recommendationReason, !reason.isEmpty {
                Label(reason, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let criteria = card.criteriaSummary {
                VStack(alignment: .leading, spacing: 2) {
                    Text("vnext.today.done_when")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(criteria)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                performPrimaryAction(card)
            } label: {
                Label(
                    primaryActionTitle(card.primaryAction),
                    systemImage: primaryActionIcon(card.primaryAction)
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(primaryActionTint(card))
            .accessibilityLabel("\(primaryActionTitle(card.primaryAction)) \(card.item.title)")
            .studioZoomSource(id: "practice-zoom-upnext", namespace: practiceTimerZoomNamespace)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func subtitle(for card: VNextTodayUpNextCard) -> String {
        var parts = [card.courseName, card.phaseName].compactMap { $0 }
        if let minutes = card.item.durationMinutes {
            parts.append("\(minutes) min")
        }
        return parts.isEmpty ? card.item.detail : parts.joined(separator: " · ")
    }

    private func primaryActionTitle(_ action: VNextTodayPrimaryAction) -> String {
        switch action {
        case .start: String(localized: "vnext.today.start")
        case .resumeCapture: String(localized: "vnext.today.continue")
        case .startPractice: String(localized: "vnext.today.practice.start")
        case .resumePractice, .resumePracticeCompletion:
            String(localized: "vnext.today.practice.continue")
        }
    }

    private func primaryActionIcon(_ action: VNextTodayPrimaryAction) -> String {
        switch action {
        case .start: "play.fill"
        case .resumeCapture: "play.fill"
        case .startPractice, .resumePractice, .resumePracticeCompletion: "play.fill"
        }
    }

    /// Practice actions use the routine's own color so the button and the
    /// timer screen it opens share one color; everything else stays accent.
    private func primaryActionTint(_ card: VNextTodayUpNextCard) -> Color {
        switch card.primaryAction {
        case .start, .resumeCapture:
            return StudioTheme.accent
        case .startPractice, .resumePractice, .resumePracticeCompletion:
            guard let routine = viewModel.snapshot.operationalPracticeRoutines.first(where: {
                $0.id == card.item.sourceID
            }) else {
                return StudioTheme.accent
            }
            return StudioTheme.practiceColor(routine.color)
        }
    }

    private func upNextMenu(_ card: VNextTodayUpNextCard) -> some View {
        Menu {
            if projection.alternatives.first != nil {
                Button {
                    swapWithFirstAlternative()
                } label: {
                    Label(String(localized: "vnext.today.menu.swap"), systemImage: "arrow.2.squarepath")
                }
            }
            Button {
                setAgendaPosition(.laterToday, for: card.item)
            } label: {
                Label(String(localized: "vnext.today.menu.later"), systemImage: "clock")
            }
            Button(role: .destructive) {
                setAgendaPosition(.skipToday, for: card.item)
            } label: {
                Label(String(localized: "vnext.today.menu.skip"), systemImage: "forward.end")
            }
            if let session = card.plannedSession,
               let project = viewModel.projects.first(where: { $0.id == session.projectId }),
               let plan = viewModel.learningPlans.first(where: { $0.id == session.planId }) {
                NavigationLink {
                    CoursePlanDetailView(viewModel: viewModel, project: project, plan: plan)
                } label: {
                    Label(String(localized: "vnext.today.menu.view_plan"), systemImage: "map")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel(Text("vnext.today.menu.accessibility"))
    }

    // MARK: Alternatives

    @ViewBuilder
    private var alternativeRows: some View {
        ForEach(projection.alternatives) { item in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                    Text(alternativeSubtitle(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if item.source == .practiceRoutine {
                    Button {
                        startPracticeFromAgenda(item.sourceID)
                    } label: {
                        Text(practiceActionTitle(for: item.sourceID))
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(
                        "\(practiceActionTitle(for: item.sourceID)) \(item.title)"
                    )
                }
                Button {
                    setAgendaPosition(.upNext, for: item)
                } label: {
                    Text("vnext.today.alt.swap")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(
                    "\(String(localized: "vnext.today.alt.swap")) \(item.title)"
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func alternativeSubtitle(_ item: TodayAgendaItem) -> String {
        if let minutes = item.durationMinutes {
            return "\(item.detail) · \(minutes) min"
        }
        return item.detail
    }

    // MARK: View all / adjust today

    private var viewAllEntry: some View {
        HStack {
            Button {
                showingFullAgenda = true
            } label: {
                Label(String(localized: "vnext.today.view_all"), systemImage: "list.bullet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func performPrimaryAction(_ card: VNextTodayUpNextCard) {
        switch card.primaryAction {
        case let .resumeCapture(captureID):
            if let active = viewModel.activeStudyCapture(), active.id == captureID {
                reopeningCapture = active
            } else {
                reopeningCapture = viewModel.pendingStudyCaptures().first { $0.id == captureID }
            }
        case .start:
            start(card.item, plannedSession: card.plannedSession)
        case .startPractice, .resumePractice, .resumePracticeCompletion:
            start(card.item, plannedSession: card.plannedSession, zoomSourceID: "practice-zoom-upnext")
        }
    }

    private func start(_ item: TodayAgendaItem, plannedSession: PlannedSession?, zoomSourceID: String? = nil) {
        switch item.source {
        case .plannedSession:
            guard let session = plannedSession,
                  let project = viewModel.projects.first(where: { $0.id == session.projectId }) else {
                return
            }
            startingContext = PlannedSessionContext(
                session: session,
                project: project,
                phase: viewModel.planPhases.first { $0.id == session.phaseId }
            )
        case .nextStep:
            guard let project = viewModel.projects.first(where: { $0.id == item.projectID }) else { return }
            startingProject = project
        case .practiceRoutine:
            startPracticeFromAgenda(item.sourceID, zoomSourceID: zoomSourceID)
        }
    }

    private func practiceActionTitle(for routineID: UUID) -> String {
        if practiceTimer.pendingCompletion != nil || practiceTimer.snapshot.activeRoutineId != nil {
            return String(localized: "vnext.today.practice.continue")
        }
        return String(localized: "vnext.today.practice.start")
    }

    /// Opens the selected practice routine directly from any agenda position.
    /// If the runtime already owns a timer or pending completion, this resolves
    /// to that routine instead of attempting a second start.
    private func startPracticeFromAgenda(_ routineID: UUID, zoomSourceID: String? = nil) {
        if let pendingRoutineID = practiceTimer.pendingCompletion?.completion.routineId {
            openPracticeRoutine(pendingRoutineID, zoomSourceID: zoomSourceID)
            return
        }
        if let activeRoutineID = practiceTimer.snapshot.activeRoutineId {
            openPracticeRoutine(activeRoutineID, zoomSourceID: zoomSourceID)
            return
        }
        openPracticeRoutine(routineID, zoomSourceID: zoomSourceID)
    }

    private func prepareInlinePractice() {
        if effectivePracticeProjectID != nil, selectedPracticeProjectID == nil {
            selectedPracticeProjectID = effectivePracticeProjectID
        }
    }

    private func practiceModeTitle(_ mode: PracticeTimerMode) -> String {
        switch mode {
        case .countUp:
            String(localized: "vnext.today.practice.setup.count_up")
        case .countdown:
            String(localized: "vnext.today.practice.setup.countdown")
        }
    }

    /// Starts a project-owned timer in place. Today immediately replaces the
    /// launcher with live pause and finish controls.
    private func startInlinePractice() {
        guard practiceTimer.pendingCompletion == nil,
              practiceTimer.snapshot.activeRoutineId == nil,
              let projectID = effectivePracticeProjectID else {
            if let routineID = practiceTimer.pendingCompletion?.completion.routineId
                ?? practiceTimer.snapshot.activeRoutineId {
                openPracticeRoutine(routineID)
            }
            return
        }
        do {
            _ = try viewModel.startSimplePractice(
                projectId: projectID,
                mode: practiceMode,
                countdownMinutes: practiceCountdownMinutes
            )
        } catch {
            practiceActionError = error.localizedDescription
        }
    }

    private func quickFinishPractice(_ routine: PracticeRoutine) {
        practiceTimer.refresh()
        do {
            guard try viewModel.finishAndSavePractice(linkedProjectId: routine.projectId) != nil else {
                practiceActionError = String(localized: "vnext.today.practice.finish_failed")
                return
            }
        } catch {
            practiceActionError = error.localizedDescription
        }
    }

    private var practiceActionErrorPresented: Binding<Bool> {
        Binding {
            practiceActionError != nil
        } set: { isPresented in
            if !isPresented { practiceActionError = nil }
        }
    }

    private func openPracticeRoutine(_ routineID: UUID, zoomSourceID: String? = nil) {
        guard let routine = practiceRoutineForTimer(routineID) else { return }
        practiceZoomSourceID = zoomSourceID
        startingPractice = routine
    }

    private func practiceRoutineForTimer(_ routineID: UUID) -> PracticeRoutine? {
        viewModel.practiceRoutineForTimer(
            routineID,
            now: practiceTimer.lastRefreshDate
        )
    }

    private func swapWithFirstAlternative() {
        guard let alternative = projection.alternatives.first else { return }
        setAgendaPosition(.upNext, for: alternative)
    }

    private func setAgendaPosition(_ position: TodayAgendaPosition, for item: TodayAgendaItem) {
        viewModel.applyTodayAgendaOverride(
            TodayAgendaOverride(
                day: practiceTimer.lastRefreshDate,
                source: item.source,
                sourceID: item.sourceID,
                position: position
            )
        )
    }
}

/// The everyday Practice entry intentionally exposes only the decisions needed
/// at the moment of practice. Routine authoring remains a compatibility detail,
/// not a prerequisite for starting a timer.
public struct SimplePracticeSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: JournalViewModel
    @State private var selectedProjectID: UUID?
    @State private var mode: PracticeTimerMode = .countUp
    @State private var countdownMinutes = 25
    @State private var startedRoutine: PracticeRoutine?
    @State private var errorMessage: String?

    public init(viewModel: JournalViewModel, initialProjectID: UUID? = nil) {
        self.viewModel = viewModel
        _selectedProjectID = State(initialValue: initialProjectID)
    }

    public var body: some View {
        Group {
            if let startedRoutine {
                PracticeTimerView(viewModel: viewModel, routine: startedRoutine)
            } else {
                NavigationStack {
                    Group {
                        if projects.isEmpty {
                            ContentUnavailableView(
                                String(localized: "vnext.today.practice.setup.no_projects"),
                                systemImage: "folder.badge.plus",
                                description: Text("vnext.today.practice.setup.no_projects_hint")
                            )
                        } else {
                            Form {
                                projectSection
                                timerSection
                                startSection
                            }
                        }
                    }
                    .navigationTitle(Text("vnext.today.practice.setup.title"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel(Text("vnext.today.practice.setup.close"))
                        }
                    }
                }
            }
        }
        .onAppear(perform: prepare)
        .alert("vnext.today.practice.setup.error", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? String(localized: "vnext.today.practice.setup.error_hint"))
        }
    }

    private var projectSection: some View {
        Section("vnext.today.practice.setup.project") {
            projectWheel
        }
    }

    @ViewBuilder
    private var projectWheel: some View {
        #if os(iOS)
        Picker("vnext.today.practice.setup.project", selection: $selectedProjectID) {
            ForEach(projects) { project in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(project.name)
                }
                .tag(Optional(project.id))
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity, minHeight: 116, maxHeight: 132)
        .clipped()
        .accessibilityLabel(Text("vnext.today.practice.setup.project"))
        #else
        Picker("vnext.today.practice.setup.project", selection: $selectedProjectID) {
            ForEach(projects) { project in
                Text(project.name).tag(Optional(project.id))
            }
        }
        .pickerStyle(.menu)
        #endif
    }

    private var timerSection: some View {
        Section("vnext.today.practice.setup.timer") {
            Picker("vnext.today.practice.setup.mode", selection: $mode) {
                ForEach(PracticeTimerMode.allCases, id: \.self) { timerMode in
                    Text(modeTitle(timerMode)).tag(timerMode)
                }
            }
            .pickerStyle(.segmented)

            if mode == .countdown {
                countdownWheel
            }
        }
        .animation(.smooth(duration: 0.28), value: mode)
    }

    @ViewBuilder
    private var countdownWheel: some View {
        #if os(iOS)
        Picker("vnext.today.practice.setup.duration", selection: $countdownMinutes) {
            ForEach(1...180, id: \.self) { minutes in
                Text(
                    String(
                        format: String(localized: "vnext.today.practice.setup.minutes"),
                        minutes
                    )
                )
                .tag(minutes)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 156)
        .clipped()
        .accessibilityLabel(Text("vnext.today.practice.setup.duration"))
        .accessibilityValue(
            Text(
                String(
                    format: String(localized: "vnext.today.practice.setup.minutes"),
                    countdownMinutes
                )
            )
        )
        #else
        Picker("vnext.today.practice.setup.duration", selection: $countdownMinutes) {
            ForEach(1...180, id: \.self) { minutes in
                Text(
                    String(
                        format: String(localized: "vnext.today.practice.setup.minutes"),
                        minutes
                    )
                )
                .tag(minutes)
            }
        }
        .pickerStyle(.menu)
        #endif
    }

    private var startSection: some View {
        Section {
            Button(action: start) {
                Label("vnext.today.practice.setup.start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(selectedProjectID == nil)
        }
    }

    private var projects: [Project] {
        viewModel.projects
            .filter { $0.deletedAt == nil && !$0.isTrashed }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func modeTitle(_ mode: PracticeTimerMode) -> String {
        switch mode {
        case .countUp:
            String(localized: "vnext.today.practice.setup.count_up")
        case .countdown:
            String(localized: "vnext.today.practice.setup.countdown")
        }
    }

    private func prepare() {
        if let pendingID = viewModel.practiceTimer.pendingCompletion?.completion.routineId,
           let routine = viewModel.practiceRoutineForTimer(pendingID) {
            startedRoutine = routine
            return
        }
        if let activeID = viewModel.practiceTimer.snapshot.activeRoutineId,
           let routine = viewModel.practiceRoutineForTimer(activeID) {
            startedRoutine = routine
            return
        }
        if selectedProjectID == nil, projects.count == 1 {
            selectedProjectID = projects[0].id
        }
    }

    private func start() {
        guard let selectedProjectID else { return }
        do {
            startedRoutine = try viewModel.startSimplePractice(
                projectId: selectedProjectID,
                mode: mode,
                countdownMinutes: countdownMinutes
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding {
            errorMessage != nil
        } set: { presented in
            if !presented { errorMessage = nil }
        }
    }
}

/// The "view all / adjust today" sheet: the complete day agenda with the
/// same day-scoped override actions the old Today screen offered. Overrides
/// stay local-only; source records never change here.
private struct VNextTodayAgendaSheet: View {
    @Environment(\.dismiss) private var dismiss
    let agenda: [TodayAgendaItem]
    let onSelectPosition: (TodayAgendaPosition, TodayAgendaItem) -> Void
    let onStartPractice: (TodayAgendaItem) -> Void
    let practiceActionTitle: (UUID) -> String
    let onClearOverride: (TodayAgendaItem) -> Void

    var body: some View {
        List {
            ForEach(agenda) { item in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if item.source == .practiceRoutine {
                        Button {
                            onStartPractice(item)
                        } label: {
                            Label(
                                practiceActionTitle(item.sourceID),
                                systemImage: "play.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(
                            "\(practiceActionTitle(item.sourceID)) \(item.title)"
                        )
                    }
                    overrideMenu(item)
                }
            }
        }
        .navigationTitle(Text("vnext.today.agenda.title"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    dismiss()
                } label: {
                    Text("vnext.today.agenda.done")
                }
            }
        }
    }

    private func overrideMenu(_ item: TodayAgendaItem) -> some View {
        Menu {
            if item.position != .upNext {
                Button {
                    onSelectPosition(.upNext, item)
                } label: {
                    Text("vnext.today.agenda.make_up_next")
                }
            }
            if item.position != .laterToday {
                Button {
                    onSelectPosition(.laterToday, item)
                } label: {
                    Text("vnext.today.agenda.later")
                }
            }
            if item.position != .optional {
                Button {
                    onSelectPosition(.optional, item)
                } label: {
                    Text("vnext.today.agenda.optional")
                }
            }
            if item.position != .skipToday {
                Button {
                    onSelectPosition(.skipToday, item)
                } label: {
                    Text("vnext.today.agenda.skip")
                }
            } else {
                Button {
                    onSelectPosition(.optional, item)
                } label: {
                    Text("vnext.today.agenda.restore")
                }
            }
            Button {
                onClearOverride(item)
            } label: {
                Text("vnext.today.agenda.clear_override")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel(
            "\(String(localized: "vnext.today.agenda.adjust")) \(item.title)"
        )
    }
}


// MARK: - Press feedback button styles

/// Instant touch-down feedback: a quick critically-damped scale + opacity dip.
/// Under Reduce Motion the scale spring is dropped and only a subtle opacity
/// change remains.
private struct PressFeedbackButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(
                .spring(response: 0.18, dampingFraction: 1.0),
                value: configuration.isPressed
            )
    }
}

/// The Start button look (borderedProminent equivalent) with instant
/// touch-down feedback; reads the disabled state so an unavailable action
/// stays visually muted.
private struct ProminentPressButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    var tint: Color = StudioTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        ProminentPressBody(reduceMotion: reduceMotion, tint: tint, configuration: configuration)
    }

    private struct ProminentPressBody: View {
        let reduceMotion: Bool
        let tint: Color
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    tint,
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(
                    .spring(response: 0.18, dampingFraction: 1.0),
                    value: configuration.isPressed
                )
        }
    }
}
