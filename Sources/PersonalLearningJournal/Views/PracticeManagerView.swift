import SwiftUI

struct PracticeRoutineDraft: Equatable {
    let routineId: UUID?
    let isArchived: Bool
    var name: String
    var symbolName: String
    var color: PracticeSemanticColor
    var targetMinutes: Int
    var weekdays: Set<Int>

    init(routine: PracticeRoutine? = nil) {
        routineId = routine?.id
        isArchived = routine?.isArchived ?? false
        name = routine?.name ?? ""
        symbolName = routine?.symbolName ?? "music.note"
        color = routine?.color ?? .coral
        targetMinutes = routine?.targetMinutes ?? 30
        weekdays = routine?.weekdays ?? Set(1...7)
    }

    var trimmedName: String {
        name.trimmedForJournal
    }

    func canSave(comparedWith routines: [PracticeRoutine]) -> Bool {
        guard !trimmedName.isEmpty,
              (1...1_440).contains(targetMinutes),
              !weekdays.isEmpty,
              weekdays.allSatisfy({ (1...7).contains($0) }) else {
            return false
        }
        return !hasDuplicateActiveName(comparedWith: routines)
    }

    func hasDuplicateActiveName(comparedWith routines: [PracticeRoutine]) -> Bool {
        guard !isArchived else { return false }
        let normalizedName = normalized(trimmedName)
        return routines.contains { routine in
            routine.id != routineId
                && !routine.isArchived
                && routine.deletedAt == nil
                && normalized(routine.name) == normalizedName
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmedForJournal.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

public struct PracticeManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var practiceTimer: PracticeTimerRuntime
    @State private var editorContext: PracticeEditorContext?
    @State private var routinePendingDeletion: PracticeRoutine?
    @State private var errorMessage: String?

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
        _practiceTimer = ObservedObject(wrappedValue: viewModel.practiceTimer)
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Active") {
                    if activeRoutines.isEmpty {
                        Text("No active routines")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(activeRoutines) { routine in
                            routineRow(routine)
                        }
                    }
                }

                Section("Archived") {
                    if archivedRoutines.isEmpty {
                        Text("No archived routines")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(archivedRoutines) { routine in
                            routineRow(routine)
                        }
                    }
                }
            }
            .navigationTitle("Practice Routines")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close practice manager")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editorContext = PracticeEditorContext(routine: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add practice routine")
                }
            }
        }
        .sheet(item: $editorContext) { context in
            PracticeRoutineEditorView(viewModel: viewModel, routine: context.routine)
        }
        .confirmationDialog(
            "Delete this unused routine?",
            isPresented: deletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Routine", role: .destructive) {
                deleteRoutinePendingConfirmation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the routine. Routines with practice history can only be archived.")
        }
        .alert("Could Not Update Routine", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The routine could not be updated.")
        }
    }

    private var activeRoutines: [PracticeRoutine] {
        liveRoutines.filter { !$0.isArchived }
    }

    private var archivedRoutines: [PracticeRoutine] {
        liveRoutines.filter(\.isArchived)
    }

    private var liveRoutines: [PracticeRoutine] {
        viewModel.practiceRoutines
            .filter { $0.deletedAt == nil }
            .sorted { left, right in
                if left.createdAt != right.createdAt {
                    return left.createdAt < right.createdAt
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private func routineRow(_ routine: PracticeRoutine) -> some View {
        let sessions = sessions(for: routine)
        return Button {
            editorContext = PracticeEditorContext(routine: routine)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: routine.symbolName)
                    .font(.headline)
                    .foregroundStyle(StudioTheme.practiceColor(routine.color))
                    .frame(width: 40, height: 40)
                    .background(
                        StudioTheme.practiceColor(routine.color).opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(routine.name)
                        .font(.headline)
                    Text("\(routine.targetMinutes) min · \(weekdaySummary(for: routine))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if practiceTimer.snapshot.activeRoutineId == routine.id {
                        Label("Timer active", systemImage: "timer")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.practiceColor(routine.color))
                    }
                    if !sessions.isEmpty {
                        Text("\(sessions.count) sessions · \(StudioDurationFormat.compact(seconds: totalDuration(of: sessions)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(routineAccessibilityLabel(routine, sessions: sessions))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if practiceTimer.snapshot.activeRoutineId != routine.id, !routine.isArchived {
                Button {
                    archive(routine)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(StudioTheme.accent)
            }

            if practiceTimer.snapshot.activeRoutineId != routine.id, sessions.isEmpty {
                Button(role: .destructive) {
                    routinePendingDeletion = routine
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding {
            routinePendingDeletion != nil
        } set: { isPresented in
            if !isPresented { routinePendingDeletion = nil }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding {
            errorMessage != nil
        } set: { isPresented in
            if !isPresented { errorMessage = nil }
        }
    }

    private func sessions(for routine: PracticeRoutine) -> [PracticeSession] {
        viewModel.practiceSessions.filter {
            $0.routineId == routine.id && $0.deletedAt == nil
        }
    }

    private func totalDuration(of sessions: [PracticeSession]) -> Int {
        sessions.reduce(0) { $0 + $1.activeDurationSeconds }
    }

    private func weekdaySummary(for routine: PracticeRoutine) -> String {
        if routine.weekdays.count == 7 { return "Every day" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return routine.weekdays.sorted().compactMap { weekday in
            symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : nil
        }.joined(separator: ", ")
    }

    private func routineAccessibilityLabel(
        _ routine: PracticeRoutine,
        sessions: [PracticeSession]
    ) -> String {
        let history = sessions.isEmpty
            ? "No practice history"
            : "\(sessions.count) sessions, \(StudioDurationFormat.compact(seconds: totalDuration(of: sessions))) total"
        let timerState = practiceTimer.snapshot.activeRoutineId == routine.id ? ", timer active" : ""
        return "\(routine.name), target \(routine.targetMinutes) minutes, \(weekdaySummary(for: routine)), \(history)\(timerState)"
    }

    private func archive(_ routine: PracticeRoutine) {
        do {
            _ = try viewModel.archivePracticeRoutine(routine.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRoutinePendingConfirmation() {
        guard let routine = routinePendingDeletion else { return }
        routinePendingDeletion = nil
        do {
            try viewModel.deletePracticeRoutineIfUnused(routine.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PracticeEditorContext: Identifiable {
    let id = UUID()
    let routine: PracticeRoutine?
}

private struct PracticeRoutineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: JournalViewModel
    @State private var draft: PracticeRoutineDraft
    @State private var errorMessage: String?

    init(viewModel: JournalViewModel, routine: PracticeRoutine?) {
        self.viewModel = viewModel
        _draft = State(initialValue: PracticeRoutineDraft(routine: routine))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Routine") {
                    TextField("Name", text: $draft.name)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                        .onSubmit { draft.name = draft.trimmedName }

                    Picker("Symbol", selection: $draft.symbolName) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Label(Self.symbolLabel(symbol), systemImage: symbol)
                                .tag(symbol)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Color") {
                    HStack(spacing: 14) {
                        ForEach(PracticeSemanticColor.allCases, id: \.self) { color in
                            Button {
                                draft.color = color
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(StudioTheme.practiceColor(color))
                                    if draft.color == color {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(color.rawValue.capitalized) color")
                            .accessibilityAddTraits(draft.color == color ? .isSelected : [])
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section("Daily Target") {
                    HStack(spacing: 12) {
                        TextField("Minutes", value: $draft.targetMinutes, format: .number)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 72)
                        Text("minutes")
                            .foregroundStyle(.secondary)
                        Stepper(
                            "Target minutes",
                            value: $draft.targetMinutes,
                            in: 1...1_440
                        )
                        .labelsHidden()
                        .accessibilityLabel("Target minutes")
                        .accessibilityValue("\(draft.targetMinutes)")
                    }
                }

                Section("Practice Days") {
                    HStack(spacing: 6) {
                        ForEach(orderedWeekdays, id: \.value) { weekday in
                            Toggle(
                                weekday.shortName,
                                isOn: weekdayBinding(weekday.value)
                            )
                            .toggleStyle(.button)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle(radius: 8))
                            .tint(StudioTheme.practiceColor(draft.color))
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .accessibilityLabel(weekday.fullName)
                        }
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(StudioTheme.notice)
                    }
                }
            }
            .navigationTitle(draft.routineId == nil ? "New Practice" : "Edit Practice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel editing practice routine")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!draft.canSave(comparedWith: viewModel.practiceRoutines))
                }
            }
        }
        .alert("Could Not Save Routine", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The routine could not be saved.")
        }
    }

    private var validationMessage: String? {
        if draft.trimmedName.isEmpty { return "Enter a routine name." }
        if !(1...1_440).contains(draft.targetMinutes) { return "Choose a target from 1 to 1,440 minutes." }
        if draft.weekdays.isEmpty { return "Choose at least one practice day." }
        if draft.hasDuplicateActiveName(comparedWith: viewModel.practiceRoutines) {
            return "An active routine already uses this name."
        }
        return nil
    }

    private var orderedWeekdays: [PracticeWeekdayOption] {
        let calendar = Calendar.current
        let shortNames = calendar.veryShortStandaloneWeekdaySymbols
        let fullNames = calendar.weekdaySymbols
        return (0..<7).map { offset in
            let value = ((calendar.firstWeekday - 1 + offset) % 7) + 1
            return PracticeWeekdayOption(
                value: value,
                shortName: shortNames[value - 1],
                fullName: fullNames[value - 1]
            )
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding {
            errorMessage != nil
        } set: { isPresented in
            if !isPresented { errorMessage = nil }
        }
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding {
            draft.weekdays.contains(weekday)
        } set: { isSelected in
            if isSelected {
                draft.weekdays.insert(weekday)
            } else {
                draft.weekdays.remove(weekday)
            }
        }
    }

    private func save() {
        guard draft.canSave(comparedWith: viewModel.practiceRoutines) else { return }
        do {
            if let routineId = draft.routineId {
                _ = try viewModel.updatePracticeRoutine(
                    routineId: routineId,
                    name: draft.trimmedName,
                    symbolName: draft.symbolName,
                    color: draft.color,
                    targetMinutes: draft.targetMinutes,
                    weekdays: draft.weekdays
                )
            } else {
                _ = try viewModel.createPracticeRoutine(
                    name: draft.trimmedName,
                    symbolName: draft.symbolName,
                    color: draft.color,
                    targetMinutes: draft.targetMinutes,
                    weekdays: draft.weekdays
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let symbols = [
        "music.note",
        "guitars",
        "pianokeys",
        "mic.fill",
        "paintbrush.fill",
        "pencil.and.scribble",
        "figure.strengthtraining.traditional",
        "figure.yoga",
        "book.closed.fill",
        "character.book.closed.fill"
    ]

    private static func symbolLabel(_ symbol: String) -> String {
        switch symbol {
        case "music.note": "Music"
        case "guitars": "Guitar"
        case "pianokeys": "Piano"
        case "mic.fill": "Voice"
        case "paintbrush.fill": "Painting"
        case "pencil.and.scribble": "Writing"
        case "figure.strengthtraining.traditional": "Strength"
        case "figure.yoga": "Yoga"
        case "book.closed.fill": "Reading"
        default: "Language"
        }
    }
}

private struct PracticeWeekdayOption {
    let value: Int
    let shortName: String
    let fullName: String
}
