import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct PracticeFinishDraft: Equatable {
    let completion: PracticeTimerCompletion
    var note: String
    var linkedProjectId: UUID?
    private(set) var errorMessage: String?
    private(set) var fallbackExplanation: String?
    private(set) var isSaved = false

    init(
        completion: PracticeTimerCompletion,
        note: String = "",
        linkedProjectId: UUID? = nil
    ) {
        self.completion = completion
        self.note = note
        self.linkedProjectId = linkedProjectId
    }

    @discardableResult
    mutating func submit(
        using save: (
            _ completion: PracticeTimerCompletion,
            _ linkedProjectId: UUID?,
            _ note: String?
        ) throws -> PracticeSessionSaveResult
    ) -> Bool {
        errorMessage = nil
        fallbackExplanation = nil
        do {
            let result = try save(
                completion,
                linkedProjectId,
                note.trimmedForJournal.nilIfEmpty
            )
            isSaved = true
            if result.didDropMissingProjectLink {
                linkedProjectId = nil
                fallbackExplanation = "The linked project is no longer available. The practice session was saved without a project link."
            }
            return true
        } catch {
            isSaved = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    mutating func clearError() {
        errorMessage = nil
    }
}

public struct PracticeTimerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var timer: PracticeTimerRuntime
    private let routine: PracticeRoutine

    @State private var finishDraft: PracticeFinishDraft?
    @State private var timerError: String?
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
                if let finishDraft {
                    finishContent(finishDraft)
                } else if timer.snapshot.activeRoutineId == routine.id {
                    timerContent
                } else {
                    unavailableContent
                }
            }
            .navigationTitle(finishDraft == nil ? "Practice" : "Finish Practice")
            .toolbar {
                if finishDraft == nil {
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
        .interactiveDismissDisabled(finishDraft != nil)
        .onAppear(perform: prepareTimer)
        .confirmationDialog(
            finishDraft == nil ? "Discard this practice timer?" : "Discard this completed practice?",
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
            Button("OK") { finishDraft?.clearError() }
        } message: {
            Text(finishDraft?.errorMessage ?? "The practice session could not be saved.")
        }
        .alert("Project Link Removed", isPresented: $showingFallbackExplanation) {
            Button("Done") { dismiss() }
        } message: {
            Text(finishDraft?.fallbackExplanation ?? "The practice session was saved without a project link.")
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
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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

    private func finishContent(_ draft: PracticeFinishDraft) -> some View {
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
                .disabled(draft.isSaved)

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

    private var missingSelectedProjectID: UUID? {
        guard let projectID = finishDraft?.linkedProjectId,
              !availableProjects.contains(where: { $0.id == projectID }) else {
            return nil
        }
        return projectID
    }

    private var noteBinding: Binding<String> {
        Binding {
            finishDraft?.note ?? ""
        } set: { newValue in
            finishDraft?.note = newValue
        }
    }

    private var projectBinding: Binding<UUID?> {
        Binding {
            finishDraft?.linkedProjectId
        } set: { newValue in
            finishDraft?.linkedProjectId = newValue
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
            finishDraft?.errorMessage != nil
        } set: { isPresented in
            if !isPresented { finishDraft?.clearError() }
        }
    }

    private func prepareTimer() {
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
        guard finishDraft == nil, timer.snapshot.activeRoutineId == routine.id else { return }
        timer.refresh()
        if timer.consumeTargetCrossing() {
            sendTargetHaptic()
        }
    }

    private func sendTargetHaptic() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        #endif
    }

    private func finishPractice() {
        refreshTimer()
        guard let completion = timer.finish() else {
            timerError = "The timer could not finish. Your active practice is still available to retry."
            return
        }
        finishDraft = PracticeFinishDraft(completion: completion)
    }

    private func requestDiscard() {
        if timer.snapshot.activeElapsedSeconds > 0 {
            showingDiscardConfirmation = true
        } else {
            discardPractice()
        }
    }

    private func discardPractice() {
        if finishDraft == nil {
            viewModel.discardPractice()
        }
        dismiss()
    }

    private func saveCompletion() {
        guard var draft = finishDraft else { return }
        let didSave = draft.submit { completion, linkedProjectId, note in
            try viewModel.savePracticeCompletion(
                completion,
                linkedProjectId: linkedProjectId,
                note: note
            )
        }
        finishDraft = draft

        guard didSave else { return }
        if draft.fallbackExplanation != nil {
            showingFallbackExplanation = true
        } else {
            dismiss()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
