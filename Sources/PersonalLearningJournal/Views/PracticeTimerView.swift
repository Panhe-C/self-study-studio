import SwiftUI

public struct PracticeTimerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var timer: PracticeTimerRuntime
    private let routine: PracticeRoutine
    private let zoomSourceID: String?
    private let zoomNamespace: Namespace.ID?

    @State private var timerError: String?
    @State private var saveError: String?
    @State private var fallbackExplanation: String?
    @State private var isSaving = false
    @State private var showingDiscardConfirmation = false
    @State private var showingFallbackExplanation = false
    @State private var selectedRecoveryProjectID: UUID?
    @State private var summaryAppeared = false

    public init(
        viewModel: JournalViewModel,
        routine: PracticeRoutine,
        zoomSourceID: String? = nil,
        zoomNamespace: Namespace.ID? = nil
    ) {
        self.viewModel = viewModel
        self.routine = routine
        self.zoomSourceID = zoomSourceID
        self.zoomNamespace = zoomNamespace
        _timer = ObservedObject(wrappedValue: viewModel.practiceTimer)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let pendingDraft {
                    finishContent(pendingDraft)
                } else if timer.snapshot.activeRoutineId == routine.id {
                    timerContent
                } else {
                    unavailableContent
                }
            }
            .navigationTitle(
                pendingDraft == nil
                    ? "Practice"
                    : pendingDraftIsPersisted ? "Reflect on Practice" : "Finish Practice"
            )
            .toolbar {
                if pendingDraft == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close practice timer")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if timer.snapshot.blocks.count > 1 {
                                Button {
                                    if !timer.skipCurrentBlock() {
                                        timerError = "Choose another practice block before continuing."
                                    }
                                } label: {
                                    Label("Skip Current Block", systemImage: "forward.end.fill")
                                }
                            }
                            Button(role: .destructive, action: requestDiscard) {
                                Label("Discard Practice", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More practice actions")
                    }
                }
            }
        }
        .interactiveDismissDisabled(pendingDraft != nil)
        .studioZoomTransition(sourceID: zoomSourceID, namespace: zoomNamespace)
        .onAppear(perform: prepareTimer)
        .confirmationDialog(
            pendingDraft == nil ? "Discard this practice timer?" : "Discard this completed practice?",
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive, action: discardPractice)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This practice time will not be saved.")
        }
        .alert("Practice Unavailable", isPresented: timerErrorPresented) {
            Button("Close") { dismiss() }
        } message: {
            Text(timerError ?? "The practice timer could not be opened.")
        }
        .alert("Could Not Save Practice", isPresented: saveErrorPresented) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "The practice session could not be saved.")
        }
        .alert("Project Link Removed", isPresented: $showingFallbackExplanation) {
            Button("Done") { dismiss() }
        } message: {
            Text(fallbackExplanation ?? "The practice session was saved without a project link.")
        }
    }

    private var timerContent: some View {
        // RootView owns the app-wide one-second lifecycle tick; this view renders the
        // published runtime snapshot without starting a second refresh loop.
        ScrollView {
            VStack(spacing: 28) {
                timerSummary
                if showsBlockNavigator {
                    blockNavigator
                }
                timerControls
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, StudioTheme.pageInset)
            .padding(.vertical, 28)
        }
        .background(StudioTheme.pageBackground.ignoresSafeArea())
    }

    private var timerSummary: some View {
        let snapshot = timer.snapshot
        let progress = snapshot.mode == .countdown
            ? min(Double(snapshot.activeElapsedSeconds) / Double(max(snapshot.targetSeconds, 1)), 1)
            : 0
        let displayedSeconds = snapshot.mode == .countdown
            ? max(0, snapshot.targetSeconds - snapshot.activeElapsedSeconds)
            : snapshot.activeElapsedSeconds

        return VStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(StudioTheme.mutedSurface, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        StudioTheme.practiceColor(routine.color),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: progress)

                Image(systemName: routine.symbolName)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(StudioTheme.practiceColor(routine.color))
                    .accessibilityHidden(true)
            }
            .frame(width: 176, height: 176)
            .accessibilityElement()
            .accessibilityLabel(
                snapshot.mode == .countdown ? "Countdown progress" : "Count up timer"
            )
            .accessibilityValue(
                snapshot.mode == .countdown
                    ? "\(Int(progress * 100)) percent"
                    : StudioDurationFormat.compact(seconds: displayedSeconds)
            )

            VStack(spacing: 8) {
                Text(routine.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let projectName {
                    Label(projectName, systemImage: "folder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(StudioDurationFormat.clock(seconds: displayedSeconds))
                    .font(.system(elapsedTextStyle, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .accessibilityLabel(snapshot.mode == .countdown ? "Time remaining" : "Elapsed time")
                    .accessibilityValue(StudioDurationFormat.compact(seconds: displayedSeconds))
                if snapshot.mode == .countdown {
                    Text("Target \(StudioDurationFormat.compact(seconds: snapshot.targetSeconds))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("vnext.today.practice.setup.count_up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(
                    String(
                        format: String(localized: "vnext.today.practice.shelf.total"),
                        StudioDurationFormat.compact(seconds: accumulatedPracticeSeconds)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        // Gentle arrival: the summary settles in once instead of popping in
        // fully rendered. Reduce Motion keeps only the opacity change.
        .opacity(summaryAppeared ? 1 : 0)
        .scaleEffect(summaryAppeared || reduceMotion ? 1 : 0.92)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1.0)) {
                summaryAppeared = true
            }
        }
    }

    private var timerControls: some View {
        HStack(spacing: 12) {
            Button {
                if timer.snapshot.isRunning {
                    timer.pause()
                } else {
                    timer.resume()
                }
            } label: {
                Label(
                    timer.snapshot.isRunning ? "Pause" : "Resume",
                    systemImage: timer.snapshot.isRunning ? "pause.fill" : "play.fill"
                )
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, minHeight: StudioTheme.practiceControlSize)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .accessibilityLabel(timer.snapshot.isRunning ? "Pause practice" : "Resume practice")

            Button(action: finishPractice) {
                Label("Finish", systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: StudioTheme.practiceControlSize)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(StudioTheme.practiceColor(routine.color))
            .accessibilityLabel("Finish practice")
        }
    }

    private var showsBlockNavigator: Bool {
        timer.snapshot.blocks.count > 1
            || !(timer.snapshot.currentBlock?.focus?.isEmpty ?? true)
    }

    private var accumulatedPracticeSeconds: Int {
        let saved = PracticeStatistics.calculate(
            routine: routine,
            sessions: viewModel.practiceSessions,
            now: timer.lastRefreshDate,
            calendar: .current
        ).allTimeActiveSeconds
        return saved + timer.snapshot.activeElapsedSeconds
    }

    private var blockNavigator: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = timer.snapshot.currentBlock {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current block")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(current.name)
                        .font(.headline)
                    if let focus = current.focus, !focus.isEmpty {
                        Label(focus, systemImage: "scope")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(StudioDurationFormat.compact(seconds: current.activeDurationSeconds)) / \(current.targetMinutes) min soft target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(timer.snapshot.blocks) { block in
                Button {
                    guard timer.selectBlock(block.id) else {
                        timerError = "That practice block is no longer available."
                        return
                    }
                } label: {
                    HStack {
                        Text(block.name)
                            .lineLimit(1)
                        Spacer()
                        Text(StudioDurationFormat.compact(seconds: block.activeDurationSeconds))
                            .font(.caption.monospacedDigit())
                        if block.id == timer.snapshot.activeBlockID {
                            Image(systemName: "checkmark.circle.fill")
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(block.id == timer.snapshot.activeBlockID ? StudioTheme.accent : nil)
                .accessibilityLabel(
                    "\(block.name), \(StudioDurationFormat.compact(seconds: block.activeDurationSeconds)), \(block.id == timer.snapshot.activeBlockID ? "current" : "select")"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var elapsedTextStyle: Font.TextStyle {
        dynamicTypeSize.isAccessibilitySize ? .title2 : .largeTitle
    }

    private func finishContent(_ draft: PracticePendingCompletionDraft) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(routine.name, systemImage: routine.symbolName)
                        .font(.headline)
                        .foregroundStyle(StudioTheme.practiceColor(routine.color))
                    Text(StudioDurationFormat.clock(seconds: draft.completion.activeDurationSeconds))
                        .font(.system(.title, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                    Text(draft.completion.endedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Optional Details") {
                TextField("Note", text: noteBinding, axis: .vertical)
                    .lineLimit(3...6)
                TextField("Attention marker (optional)", text: attentionMarkerBinding)
                if let projectName {
                    LabeledContent("Project", value: projectName)
                } else {
                    Picker("Project", selection: recoveryProjectBinding) {
                        Text("Choose a project").tag(UUID?.none)
                        ForEach(availableProjects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                }
            }

            Section {
                Button(action: saveCompletion) {
                    Label(
                        pendingDraftIsPersisted ? "Save Reflection" : "Save Practice",
                        systemImage: "checkmark.circle.fill"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.practiceColor(routine.color))
                .disabled(isSaving || effectiveProjectID == nil)

                Button(action: leaveReflection) {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!pendingDraftIsPersisted)
            }
        }
    }

    private var unavailableContent: some View {
        ContentUnavailableView {
            Label("Practice Timer Unavailable", systemImage: "timer")
        } description: {
            Text("This routine is not the active practice timer.")
        } actions: {
            Button("Close") { dismiss() }
        }
    }

    private var availableProjects: [Project] {
        viewModel.projects
            .filter { $0.deletedAt == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var projectName: String? {
        guard let projectID = routine.projectId else { return nil }
        return availableProjects.first(where: { $0.id == projectID })?.name
    }

    private var effectiveProjectID: UUID? {
        if let routineProjectID = routine.projectId,
           availableProjects.contains(where: { $0.id == routineProjectID }) {
            return routineProjectID
        }
        return selectedRecoveryProjectID
    }

    private var recoveryProjectBinding: Binding<UUID?> {
        Binding {
            selectedRecoveryProjectID
        } set: { projectID in
            selectedRecoveryProjectID = projectID
            updatePendingDraft(
                note: pendingDraft?.note ?? "",
                linkedProjectId: projectID,
                attentionMarker: pendingDraft?.attentionMarker
            )
        }
    }

    private var pendingDraft: PracticePendingCompletionDraft? {
        guard timer.pendingCompletion?.completion.routineId == routine.id else { return nil }
        return timer.pendingCompletion
    }

    private var pendingDraftIsPersisted: Bool {
        guard let draft = pendingDraft else { return false }
        return viewModel.practiceSessions.contains {
            $0.id == draft.id && $0.deletedAt == nil
        }
    }

    private var noteBinding: Binding<String> {
        Binding {
            pendingDraft?.note ?? ""
        } set: { newValue in
            updatePendingDraft(
                note: newValue,
                linkedProjectId: pendingDraft?.linkedProjectId,
                attentionMarker: pendingDraft?.attentionMarker
            )
        }
    }

    private var attentionMarkerBinding: Binding<String> {
        Binding {
            pendingDraft?.attentionMarker ?? ""
        } set: { newValue in
            updatePendingDraft(
                note: pendingDraft?.note ?? "",
                linkedProjectId: pendingDraft?.linkedProjectId,
                attentionMarker: newValue
            )
        }
    }

    private var timerErrorPresented: Binding<Bool> {
        Binding {
            timerError != nil
        } set: { isPresented in
            if !isPresented { timerError = nil }
        }
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding {
            saveError != nil
        } set: { isPresented in
            if !isPresented { saveError = nil }
        }
    }

    private func prepareTimer() {
        if let pending = timer.pendingCompletion {
            if pending.completion.routineId != routine.id {
                timerError = "Save or discard the completed practice before starting \(routine.name)."
            }
            if projectName == nil, selectedRecoveryProjectID == nil {
                if let linkedProjectID = pending.linkedProjectId,
                   availableProjects.contains(where: { $0.id == linkedProjectID }) {
                    selectedRecoveryProjectID = linkedProjectID
                } else if availableProjects.count == 1 {
                    selectedRecoveryProjectID = availableProjects[0].id
                }
            }
            return
        }
        do {
            if timer.snapshot.activeRoutineId == nil {
                try viewModel.startPractice(routine)
            } else if timer.snapshot.activeRoutineId != routine.id {
                timerError = "Finish or discard the active practice before starting \(routine.name)."
                return
            }
            refreshTimer()
        } catch {
            timerError = error.localizedDescription
        }
    }

    private func refreshTimer() {
        guard pendingDraft == nil, timer.snapshot.activeRoutineId == routine.id else { return }
        timer.refresh()
    }

    private func finishPractice() {
        refreshTimer()
        do {
            guard try viewModel.finishAndSavePractice(linkedProjectId: routine.projectId) != nil else {
                timerError = "The timer could not finish. Your active practice is still available to retry."
                return
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func requestDiscard() {
        timer.refresh()
        if pendingDraft != nil || timer.snapshot.activeElapsedSeconds > 0 {
            showingDiscardConfirmation = true
        } else {
            discardPractice()
        }
    }

    private func discardPractice() {
        if pendingDraft != nil {
            guard timer.clearPendingCompletion() else {
                saveError = "The completed practice could not be discarded from this device. It is still available to retry."
                return
            }
        } else {
            viewModel.discardPractice()
            guard timer.snapshot.activeRoutineId == nil else {
                timerError = "The timer could not be discarded. Your active practice is still available."
                return
            }
        }
        dismiss()
    }

    private func saveCompletion() {
        guard let draft = pendingDraft, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if !pendingDraftIsPersisted {
                _ = try viewModel.persistPracticeCompletionBase(
                    draft.completion,
                    linkedProjectId: effectiveProjectID
                )
            }
            let result = try viewModel.savePracticeCompletion(
                draft.completion,
                linkedProjectId: effectiveProjectID,
                note: draft.note.trimmedForJournal.nilIfEmpty,
                attentionMarker: draft.attentionMarker?.trimmedForJournal.nilIfEmpty
            )
            if result.didDropMissingProjectLink {
                fallbackExplanation = "The linked project is no longer available. The practice session was saved without a project link."
            }
        } catch {
            saveError = error.localizedDescription
            return
        }

        if fallbackExplanation != nil {
            showingFallbackExplanation = true
        } else {
            dismiss()
        }
    }

    private func leaveReflection() {
        guard pendingDraftIsPersisted else {
            saveError = "Save the practice session before leaving its reflection."
            return
        }
        guard timer.clearPendingCompletion() else {
            saveError = "The reflection draft could not be cleared on this device."
            return
        }
        dismiss()
    }

    private func updatePendingDraft(
        note: String,
        linkedProjectId: UUID?,
        attentionMarker: String?
    ) {
        guard timer.updatePendingCompletion(
            note: note,
            linkedProjectId: linkedProjectId,
            attentionMarker: attentionMarker
        ) else {
            saveError = "The completion details could not be preserved on this device. Your previous draft is still available."
            return
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
