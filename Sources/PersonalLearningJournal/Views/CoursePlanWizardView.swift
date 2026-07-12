import SwiftUI

struct CoursePlanWizardView: View {
    private enum WizardStep: Int, CaseIterable {
        case course
        case time
        case draft
        case confirm

        var title: String {
            switch self {
            case .course: "Course"
            case .time: "Time"
            case .draft: "Draft"
            case .confirm: "Confirm"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: JournalViewModel
    private let project: Project
    private let revisionSource: CoursePlan?

    @State private var step: WizardStep = .course
    @State private var courseURLText: String
    @State private var courseTitle: String
    @State private var courseOutline: String
    @State private var goal: String
    @State private var expectedOutcome: String
    @State private var startsOn: Date
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var weeklyBudgetMinutes: Int
    @State private var preferredSessionMinutes: Int
    @State private var draft: CoursePlanDraft?
    @State private var persistedDraftPlan: CoursePlan?
    @State private var hasEditedDraft = false
    @State private var errorMessage: String?
    @State private var showingAISettings = false

    init(
        viewModel: JournalViewModel,
        project: Project,
        revisionSource: CoursePlan? = nil
    ) {
        self.viewModel = viewModel
        self.project = project
        self.revisionSource = revisionSource

        let savedInput = viewModel.rememberedCoursePlanningInput(for: project.id)
        let source = savedInput ?? revisionSource.map { plan in
            CoursePlanningInput(
                projectId: project.id,
                courseURL: plan.courseURL,
                courseTitle: plan.courseTitle,
                courseOutline: plan.courseOutline,
                goal: plan.goal,
                expectedOutcome: plan.expectedOutcome,
                startsOn: plan.startsOn,
                deadline: plan.deadline,
                weeklyBudgetMinutes: plan.weeklyBudgetMinutes,
                preferredSessionMinutes: project.defaultDurationMinutes
            )
        } ?? CoursePlanningInput(
            projectId: project.id,
            courseTitle: project.name,
            courseOutline: "",
            goal: project.goal,
            expectedOutcome: "",
            startsOn: Date(),
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: project.defaultDurationMinutes
        )

        _courseURLText = State(initialValue: source.courseURL?.absoluteString ?? "")
        _courseTitle = State(initialValue: source.courseTitle)
        _courseOutline = State(initialValue: source.courseOutline)
        _goal = State(initialValue: source.goal)
        _expectedOutcome = State(initialValue: source.expectedOutcome)
        _startsOn = State(initialValue: source.startsOn)
        _hasDeadline = State(initialValue: source.deadline != nil)
        _deadline = State(initialValue: source.deadline ?? Calendar.current.date(byAdding: .weekOfYear, value: 6, to: source.startsOn) ?? source.startsOn)
        _weeklyBudgetMinutes = State(initialValue: source.weeklyBudgetMinutes)
        _preferredSessionMinutes = State(initialValue: source.preferredSessionMinutes)

        if let revisionSource {
            _draft = State(initialValue: Self.draft(from: revisionSource, viewModel: viewModel))
            _persistedDraftPlan = State(initialValue: revisionSource)
        } else if let savedDraft = viewModel.draftCoursePlan, savedDraft.projectId == project.id {
            _draft = State(initialValue: Self.draft(from: savedDraft, viewModel: viewModel))
            _persistedDraftPlan = State(initialValue: savedDraft)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Plan step", selection: $step) {
                    ForEach(WizardStep.allCases, id: \.self) { step in
                        Text(step.title).tag(step)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                Form {
                    switch step {
                    case .course:
                        courseFields
                    case .time:
                        timeFields
                    case .draft:
                        draftFields
                    case .confirm:
                        confirmationFields
                    }
                }
            }
            .navigationTitle(revisionSource == nil ? "Study Plan" : "Revise Plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        viewModel.rememberCoursePlanningInput(input)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step != .confirm {
                        Button("Next") {
                            step = WizardStep(rawValue: min(step.rawValue + 1, WizardStep.confirm.rawValue)) ?? .confirm
                        }
                    }
                }
            }
            .onChange(of: input) { _, updated in
                viewModel.rememberCoursePlanningInput(updated)
            }
            .onChange(of: draft) { _, _ in
                if persistedDraftPlan != nil {
                    hasEditedDraft = true
                }
            }
            .sheet(isPresented: $showingAISettings) {
                AIReviewSettingsView()
            }
            .alert("Course plan unavailable", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var courseFields: some View {
        Group {
            Section("Course") {
                TextField("Course URL", text: $courseURLText)
                TextField("Course title", text: $courseTitle)
                TextField("Outline", text: $courseOutline, axis: .vertical)
                    .lineLimit(4...8)
            }
            Section("Outcome") {
                TextField("Goal", text: $goal, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Expected proof or outcome", text: $expectedOutcome, axis: .vertical)
                    .lineLimit(2...4)
            }
        }
    }

    private var timeFields: some View {
        Group {
            Section("Dates") {
                DatePicker("Start", selection: $startsOn, displayedComponents: .date)
                Toggle("Set deadline", isOn: $hasDeadline)
                if hasDeadline {
                    DatePicker("Deadline", selection: $deadline, in: startsOn..., displayedComponents: .date)
                }
            }
            Section("Weekly rhythm") {
                Stepper("Weekly budget: \(weeklyBudgetMinutes) min", value: $weeklyBudgetMinutes, in: 15...1_680, step: 15)
                Stepper("Session length: \(preferredSessionMinutes) min", value: $preferredSessionMinutes, in: 15...240, step: 15)
            }
        }
    }

    @ViewBuilder
    private var draftFields: some View {
        Section {
            Button {
                Task { await generateWithAI() }
            } label: {
                Label(
                    viewModel.coursePlanGenerationState == .generating ? "Generating" : "Generate with AI",
                    systemImage: "sparkles"
                )
            }
            .disabled(viewModel.coursePlanGenerationState == .generating)

            Button {
                if draft == nil {
                    draft = Self.manualDraft(for: input)
                }
            } label: {
                Label("Create Manual Draft", systemImage: "square.and.pencil")
            }

            Button {
                showingAISettings = true
            } label: {
                Label("AI Settings", systemImage: "slider.horizontal.3")
            }
        }

        if let draftBinding = Binding($draft) {
            DraftEditor(draft: draftBinding, planInput: input)
        } else {
            Section {
                ContentUnavailableView(
                    "Start a Draft",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Generate a plan or create one manually."))
            }
        }

        if !viewModel.coursePlanValidationErrors.isEmpty {
            Section("Needs attention") {
                ForEach(viewModel.coursePlanValidationErrors.indices, id: \.self) { index in
                    Text(errorText(viewModel.coursePlanValidationErrors[index]))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var confirmationFields: some View {
        if let draft {
            Section("Plan summary") {
                Text(draft.title).font(.headline)
                Text(draft.summary).foregroundStyle(.secondary)
                LabeledContent("Phases", value: "\(draft.phases.count)")
                LabeledContent("Sessions", value: "\(draft.sessions.count)")
            }
            if !draft.assumptions.isEmpty {
                Section("Assumptions") {
                    ForEach(draft.assumptions, id: \.self) { Text($0) }
                }
            }
            if !draft.warnings.isEmpty {
                Section("Warnings") {
                    ForEach(draft.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
            Section("Will create") {
                ForEach(draft.phases) { phase in
                    Label(phase.title, systemImage: "flag")
                }
                ForEach(draft.sessions) { session in
                    Label("\(session.title) · \(session.durationMinutes) min", systemImage: "checklist")
                }
            }
            Section {
                Button {
                    activateDraft()
                } label: {
                    Label("Activate Plan", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            Section {
                ContentUnavailableView(
                    "No Draft Yet",
                    systemImage: "doc.badge.plus",
                    description: Text("Create a draft before confirming."))
            }
        }
    }

    private var input: CoursePlanningInput {
        CoursePlanningInput(
            projectId: project.id,
            courseURL: URL(string: courseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
            courseTitle: courseTitle,
            courseOutline: courseOutline,
            goal: goal,
            expectedOutcome: expectedOutcome,
            startsOn: startsOn,
            deadline: hasDeadline ? deadline : nil,
            weeklyBudgetMinutes: weeklyBudgetMinutes,
            preferredSessionMinutes: preferredSessionMinutes
        )
    }

    private func generateWithAI() async {
        do {
            let plan = try await viewModel.generateCoursePlan(input)
            persistedDraftPlan = plan
            draft = Self.draft(from: plan, viewModel: viewModel)
            hasEditedDraft = false
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func activateDraft() {
        guard let draft else { return }
        do {
            let plan: CoursePlan
            if let persistedDraftPlan, !hasEditedDraft {
                plan = persistedDraftPlan
            } else if let revisionSource {
                plan = try viewModel.reviseCoursePlan(planID: revisionSource.id, input: input, draft: draft)
            } else {
                plan = try viewModel.saveManualDraft(input: input, draft: draft)
            }
            try viewModel.activateCoursePlan(draftPlanID: plan.id)
            dismiss()
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func errorText(_ error: Error) -> String {
        if let error = error as? CoursePlanningError {
            switch error {
            case .configurationRequired:
                return "Add an AI endpoint, model, and key in AI Settings before generating."
            case .invalidDraft(let errors):
                return errors.map(errorText).joined(separator: "\n")
            case .providerUnavailable:
                return "The AI provider did not return a usable plan. Your input is still available."
            }
        }
        if let error = error as? CoursePlanningValidationError {
            return errorText(error)
        }
        return error.localizedDescription
    }

    private func errorText(_ error: CoursePlanningValidationError) -> String {
        switch error {
        case .emptyTitle: "Add a course and phase title."
        case .emptyGoal: "Add a goal and phase objective."
        case .invalidWeeklyBudget: "Set a positive weekly budget."
        case .invalidDateRange: "Check the plan dates."
        case .unknownPhaseReference: "Assign every session to a phase."
        case .invalidDuration: "Set a positive session duration."
        case .duplicateDraftID: "Each phase and session needs a distinct identifier."
        case .phaseOutsidePlan: "Keep phase dates within the course window."
        case .invalidRevision: "The plan revision is invalid."
        case .invalidOrdinal: "The phase order is invalid."
        }
    }

    private static func draft(from plan: CoursePlan, viewModel: JournalViewModel) -> CoursePlanDraft {
        let phases = viewModel.phases(for: plan.id)
        let phaseIDs = Dictionary(uniqueKeysWithValues: phases.map { ($0.id, $0.id.uuidString) })
        return CoursePlanDraft(
            title: plan.courseTitle,
            summary: plan.summary,
            phases: phases.map {
                CoursePlanDraftPhase(
                    id: $0.id.uuidString,
                    title: $0.title,
                    objective: $0.objective,
                    expectedProof: $0.expectedProof,
                    ordinal: $0.ordinal,
                    targetStart: $0.targetStart,
                    targetEnd: $0.targetEnd
                )
            },
            sessions: viewModel.plannedSessions(for: plan.id).map {
                CoursePlanDraftSession(
                    id: $0.id.uuidString,
                    phaseID: phaseIDs[$0.phaseId] ?? "",
                    title: $0.title,
                    actionType: $0.actionType,
                    expectedProof: $0.expectedProof,
                    durationMinutes: $0.durationMinutes,
                    deadline: $0.deadline
                )
            }
        )
    }

    private static func manualDraft(for input: CoursePlanningInput) -> CoursePlanDraft {
        let phaseID = "phase-\(UUID().uuidString)"
        return CoursePlanDraft(
            title: input.courseTitle,
            summary: "",
            phases: [
                CoursePlanDraftPhase(
                    id: phaseID,
                    title: "Start",
                    objective: input.goal,
                    expectedProof: input.expectedOutcome,
                    ordinal: 0,
                    targetStart: input.startsOn,
                    targetEnd: input.deadline ?? Calendar.current.date(byAdding: .weekOfYear, value: 1, to: input.startsOn) ?? input.startsOn
                )
            ],
            sessions: []
        )
    }
}

private struct DraftEditor: View {
    @Binding var draft: CoursePlanDraft
    let planInput: CoursePlanningInput

    var body: some View {
        Section("Draft") {
            TextField("Plan title", text: $draft.title)
            TextField("Summary", text: $draft.summary, axis: .vertical)
                .lineLimit(2...4)
        }

        ForEach(Array(draft.phases.indices), id: \.self) { index in
            Section("Phase \(index + 1)") {
                HStack {
                    TextField("Title", text: $draft.phases[index].title)
                    Spacer()
                    Button { movePhase(index, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0)
                    Button { movePhase(index, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == draft.phases.count - 1)
                    Button(role: .destructive) { draft.phases.remove(at: index) } label: { Image(systemName: "trash") }
                }
                TextField("Objective", text: $draft.phases[index].objective, axis: .vertical)
                TextField("Expected proof", text: $draft.phases[index].expectedProof, axis: .vertical)
                DatePicker("Start", selection: $draft.phases[index].targetStart, displayedComponents: .date)
                DatePicker("End", selection: $draft.phases[index].targetEnd, in: draft.phases[index].targetStart..., displayedComponents: .date)
            }
        }

        Section {
            Button {
                draft.phases.append(
                    CoursePlanDraftPhase(
                        id: "phase-\(UUID().uuidString)",
                        title: "New phase",
                        objective: planInput.goal,
                        expectedProof: planInput.expectedOutcome,
                        ordinal: draft.phases.count,
                        targetStart: planInput.startsOn,
                        targetEnd: planInput.deadline ?? planInput.startsOn
                    )
                )
            } label: {
                Label("Add Phase", systemImage: "plus")
            }
        }

        ForEach(Array(draft.sessions.indices), id: \.self) { index in
            Section("Session \(index + 1)") {
                HStack {
                    TextField("Title", text: $draft.sessions[index].title)
                    Spacer()
                    Button { moveSession(index, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0)
                    Button { moveSession(index, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == draft.sessions.count - 1)
                    Button(role: .destructive) { draft.sessions.remove(at: index) } label: { Image(systemName: "trash") }
                }
                Picker("Phase", selection: $draft.sessions[index].phaseID) {
                    ForEach(draft.phases) { phase in
                        Text(phase.title).tag(phase.id)
                    }
                }
                Picker("Action", selection: $draft.sessions[index].actionType) {
                    ForEach(ActionType.allCases, id: \.self) { action in
                        Text(action.rawValue.capitalized).tag(action)
                    }
                }
                Stepper("Duration: \(draft.sessions[index].durationMinutes) min", value: $draft.sessions[index].durationMinutes, in: 15...240, step: 15)
                TextField("Expected proof", text: optionalTextBinding(for: index), axis: .vertical)
            }
        }

        Section {
            Button {
                guard let phase = draft.phases.first else { return }
                draft.sessions.append(
                    CoursePlanDraftSession(
                        id: "session-\(UUID().uuidString)",
                        phaseID: phase.id,
                        title: "New study session",
                        actionType: .course,
                        expectedProof: planInput.expectedOutcome,
                        durationMinutes: planInput.preferredSessionMinutes,
                        deadline: planInput.deadline
                    )
                )
            } label: {
                Label("Add Session", systemImage: "plus")
            }
            .disabled(draft.phases.isEmpty)
        }
    }

    private func optionalTextBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { draft.sessions[index].expectedProof ?? "" },
            set: { draft.sessions[index].expectedProof = $0.isEmpty ? nil : $0 }
        )
    }

    private func movePhase(_ index: Int, by offset: Int) {
        let target = index + offset
        guard draft.phases.indices.contains(target) else { return }
        draft.phases.swapAt(index, target)
        for index in draft.phases.indices {
            draft.phases[index].ordinal = index
        }
    }

    private func moveSession(_ index: Int, by offset: Int) {
        let target = index + offset
        guard draft.sessions.indices.contains(target) else { return }
        draft.sessions.swapAt(index, target)
    }
}
