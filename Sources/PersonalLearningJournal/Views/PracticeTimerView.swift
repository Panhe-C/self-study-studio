import SwiftUI

public struct PracticeTimerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var timer: PracticeTimerRuntime
    private let routine: PracticeRoutine

    @State private var timerError: String?
    @State private var saveError: String?
    @State private var fallbackExplanation: String?
    @State private var isSaving = false
    @State private var showingDiscardConfirmation = false
    @State private var showingFallbackExplanation = false

    public init(viewModel: JournalViewModel, routine: PracticeRoutine) {
        self.viewModel = viewModel
        self.routine = routine
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
            .navigationTitle(pendingDraft == nil ? "Practice" : "Finish Practice")
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
                }
            }
        }
        .interactiveDismissDisabled(pendingDraft != nil)
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
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                VStack(spacing: 28) {
                    timerSummary
                    timerControls
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, StudioTheme.pageInset)
                .padding(.vertical, 28)
            }
            .background(StudioTheme.pageBackground.ignoresSafeArea())
            .onChange(of: timeline.date, initial: true) { _, _ in
                refreshTimer()
            }
        }
    }

    private var timerSummary: some View {
        let snapshot = timer.snapshot
        let progress = min(
            Double(snapshot.activeElapsedSeconds) / Double(max(snapshot.targetSeconds, 1)),
            1
        )

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

                Image(systemName: routine.symbolName)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(StudioTheme.practiceColor(routine.color))
                    .accessibilityHidden(true)
            }
            .frame(width: 176, height: 176)
            .accessibilityElement()
            .accessibilityLabel("Target progress")
            .accessibilityValue("\(Int(progress * 100)) percent")

            VStack(spacing: 8) {
                Text(routine.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(StudioDurationFormat.clock(seconds: snapshot.activeElapsedSeconds))
                    .font(.system(elapsedTextStyle, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(StudioDurationFormat.compact(seconds: snapshot.activeElapsedSeconds))
                Text("Target \(StudioDurationFormat.compact(seconds: snapshot.targetSeconds))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timerControls: some View {
        HStack(spacing: 22) {
            Button {
                if timer.snapshot.isRunning {
                    timer.pause()
                } else {
                    timer.resume()
                }
            } label: {
                Image(systemName: timer.snapshot.isRunning ? "pause.fill" : "play.fill")
                    .frame(width: StudioTheme.practiceControlSize, height: StudioTheme.practiceControlSize)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(timer.snapshot.isRunning ? "Pause practice" : "Resume practice")

            Button(action: finishPractice) {
                Image(systemName: "checkmark")
                    .frame(width: StudioTheme.practiceControlSize, height: StudioTheme.practiceControlSize)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(StudioTheme.practiceColor(routine.color))
            .accessibilityLabel("Finish practice")

            Button(role: .destructive, action: requestDiscard) {
                Image(systemName: "trash")
                    .frame(width: StudioTheme.practiceControlSize, height: StudioTheme.practiceControlSize)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Discard practice")
        }
        .frame(height: StudioTheme.practiceControlSize + 18)
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

                Picker("Related Project", selection: projectBinding) {
                    Text("None").tag(Optional<UUID>.none)
                    if let missingProjectID = missingSelectedProjectID {
                        Text("Unavailable Project").tag(Optional(missingProjectID))
                    }
                    ForEach(availableProjects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
            }

            Section {
                Button(action: saveCompletion) {
                    Label("Save Practice", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.practiceColor(routine.color))
                .disabled(isSaving)

                Button(role: .destructive) {
                    showingDiscardConfirmation = true
                } label: {
                    Label("Discard Completion", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
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

    private var pendingDraft: PracticePendingCompletionDraft? {
        guard timer.pendingCompletion?.completion.routineId == routine.id else { return nil }
        return timer.pendingCompletion
    }

    private var missingSelectedProjectID: UUID? {
        guard let projectID = pendingDraft?.linkedProjectId,
              !availableProjects.contains(where: { $0.id == projectID }) else {
            return nil
        }
        return projectID
    }

    private var noteBinding: Binding<String> {
        Binding {
            pendingDraft?.note ?? ""
        } set: { newValue in
            updatePendingDraft(note: newValue, linkedProjectId: pendingDraft?.linkedProjectId)
        }
    }

    private var projectBinding: Binding<UUID?> {
        Binding {
            pendingDraft?.linkedProjectId
        } set: { newValue in
            updatePendingDraft(note: pendingDraft?.note ?? "", linkedProjectId: newValue)
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
        guard timer.finish() != nil else {
            timerError = "The timer could not finish. Your active practice is still available to retry."
            return
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
            let result = try viewModel.savePracticeCompletion(
                draft.completion,
                linkedProjectId: draft.linkedProjectId,
                note: draft.note.trimmedForJournal.nilIfEmpty
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

    private func updatePendingDraft(note: String, linkedProjectId: UUID?) {
        guard timer.updatePendingCompletion(note: note, linkedProjectId: linkedProjectId) else {
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
