import SwiftUI

public struct ProgressRootView: View {
    @ObservedObject private var session: ProgressApplicationSession
    @State private var path: [UUID] = []
    @State private var activeDraft: ContentProgress.Draft?
    @State private var showingLockSettings = false

    public init(session: ProgressApplicationSession) { self.session = session }

    public var body: some View {
        NavigationStack(path: $path) {
            Group {
                if session.projects.isEmpty {
                    ContentUnavailableView {
                        Label("还没有学习项目", systemImage: "books.vertical")
                    } description: {
                        Text("创建项目，按学习内容追踪进度。")
                    } actions: {
                        Button("创建第一个项目", action: createDraft)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(session.projects) { project in
                                Button { path.append(project.id) } label: {
                                    ProgressProjectCard(project: project)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("从上次的位置继续")
                        }
                    }
                }
            }
            .navigationTitle("学习内容进度")
            .safeAreaInset(edge: .bottom) {
                Text("仅保存在此设备")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("创建项目", systemImage: "plus", action: createDraft)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        if let draft = session.drafts.first {
                            Button("继续创建草稿") { activeDraft = draft }
                        }
                        NavigationLink("查看旧版学习记录") {
                            LegacyJournalHostView()
                        }
                        Button("应用锁定设置") { showingLockSettings = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ProgressDetailView(session: session, projectID: id)
            }
            .sheet(item: $activeDraft) { draft in
                ProgressDraftView(session: session, initialDraft: draft) { project in
                    activeDraft = nil
                    path.append(project.id)
                }
            }
            .sheet(isPresented: $showingLockSettings) { ProgressLockSettingsView() }
            .alert("保存失败", isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.clearError() } }
            )) {
                Button("确定") { session.clearError() }
            } message: {
                Text(session.errorMessage ?? "")
            }
        }
    }

    private func createDraft() {
        if let draft = session.startDraft() { activeDraft = draft }
    }
}

private struct ProgressProjectCard: View {
    let project: ContentProgress.Project

    var body: some View {
        let projection = ContentProgress.projection(for: project)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(project.name).font(.headline)
                Spacer()
                if project.isPaused { Text("已暂停").font(.caption).foregroundStyle(.secondary) }
            }
            ProgressView(value: Double(projection.completed), total: Double(max(1, projection.total)))
                .accessibilityLabel("\(project.name) 完成进度")
            Text("\(projection.percentage)% · \(projection.completed)/\(projection.total) 已完成")
                .font(.subheadline)
            Text("当前：\(title(for: projection.currentUnitID) ?? "无")")
                .font(.subheadline)
            Text("下一单元：\(title(for: projection.nextUnitID) ?? "无")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }

    private func title(for id: UUID?) -> String? {
        project.units.first { $0.id == id }?.title
    }
}

private struct ProgressDetailView: View {
    @ObservedObject var session: ProgressApplicationSession
    let projectID: UUID
    @State private var newTitle = ""
    @State private var editingUnit: ContentProgress.LearningUnit?
    @State private var editedTitle = ""
    @State private var deletingUnit: ContentProgress.LearningUnit?

    var body: some View {
        Group {
            if let project = session.projects.first(where: { $0.id == projectID }) {
                let projection = ContentProgress.projection(for: project)
                ScrollViewReader { scroll in
                    List {
                        Section {
                            ProgressProjectCard(project: project)
                            if project.isPaused {
                                Text("项目已暂停。恢复后可继续标记完成。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section("学习单元") {
                            ForEach(project.units) { unit in
                                HStack(spacing: 12) {
                                    Button {
                                        session.updateProject(id: projectID) {
                                            try ContentProgress.setCompleted(
                                                $0, unitID: unit.id,
                                                completed: !unit.isCompleted
                                            )
                                        }
                                    } label: {
                                        Image(systemName: unit.isCompleted ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(unit.isCompleted ? .green : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(project.isPaused)
                                    .accessibilityLabel(unit.isCompleted ? "取消完成 \(unit.title)" : "完成 \(unit.title)")
                                    VStack(alignment: .leading) {
                                        Text(unit.title)
                                        if let date = unit.completedAt {
                                            Text(date, style: .date)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("修改", systemImage: "pencil") {
                                        editingUnit = unit
                                        editedTitle = unit.title
                                    }
                                    .labelStyle(.iconOnly)
                                }
                                .id(unit.id)
                                .swipeActions(edge: .trailing) {
                                    Button("删除", role: .destructive) { deletingUnit = unit }
                                }
                            }
                            .onMove { source, destination in
                                var ids = project.units.map(\.id)
                                ids.move(fromOffsets: source, toOffset: destination)
                                session.updateProject(id: projectID) {
                                    try ContentProgress.reorder($0, ids: ids)
                                }
                            }
                            HStack {
                                TextField("新学习单元标题", text: $newTitle)
                                    .submitLabel(.done)
                                    .onSubmit { addUnit() }
                                Button("添加", action: addUnit)
                                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    .onChange(of: projection.currentUnitID) { _, next in
                        if let next {
                            withAnimation { scroll.scrollTo(next, anchor: .center) }
                        }
                    }
                }
                .navigationTitle(project.name)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(project.isPaused ? "恢复项目" : "暂停项目") {
                            session.updateProject(id: projectID) {
                                try ContentProgress.setPaused($0, paused: !project.isPaused)
                            }
                        }
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .secondaryAction) { EditButton() }
                    #endif
                }
            } else {
                ContentUnavailableView("找不到项目", systemImage: "exclamationmark.triangle")
            }
        }
        .alert("修改学习单元", isPresented: Binding(
            get: { editingUnit != nil },
            set: { if !$0 { editingUnit = nil } }
        )) {
            TextField("标题", text: $editedTitle)
            Button("取消", role: .cancel) { editingUnit = nil }
            Button("保存") {
                guard let unit = editingUnit else { return }
                session.updateProject(id: projectID) {
                    try ContentProgress.renameUnit($0, unitID: unit.id, title: editedTitle)
                }
                editingUnit = nil
            }
        }
        .confirmationDialog("删除这个学习单元？", isPresented: Binding(
            get: { deletingUnit != nil },
            set: { if !$0 { deletingUnit = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let unit = deletingUnit else { return }
                session.updateProject(id: projectID) {
                    try ContentProgress.deleteUnit($0, unitID: unit.id)
                }
                deletingUnit = nil
            }
        }
    }

    private func addUnit() {
        let title = newTitle
        session.updateProject(id: projectID) {
            try ContentProgress.addUnit($0, title: title)
        }
        if session.errorMessage == nil { newTitle = "" }
    }
}

private struct ProgressDraftView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProgressApplicationSession
    @State var draft: ContentProgress.Draft
    let onCreated: (ContentProgress.Project) -> Void

    init(
        session: ProgressApplicationSession,
        initialDraft: ContentProgress.Draft,
        onCreated: @escaping (ContentProgress.Project) -> Void
    ) {
        self.session = session
        _draft = State(initialValue: initialDraft)
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            List {
                Section("项目名称") {
                    TextField("例如：学习 React", text: $draft.name)
                }
                Section {
                    ForEach($draft.units) { $unit in
                        TextField("学习单元", text: $unit.title)
                    }
                    .onDelete { draft.units.remove(atOffsets: $0) }
                    .onMove { draft.units.move(fromOffsets: $0, toOffset: $1) }
                    Button("添加单元", systemImage: "plus") {
                        draft.units.append(.init(title: ""))
                    }
                } header: {
                    Text("学习单元")
                } footer: {
                    Text("当前可手动建立内容结构；AI 初始化将在下一阶段接入。")
                }
            }
            .navigationTitle("创建学习项目")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        session.discardDraft(id: draft.id)
                        if session.errorMessage == nil { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认创建") {
                        guard session.saveDraft(draft) else { return }
                        if let project = session.confirmDraft(id: draft.id) {
                            dismiss()
                            onCreated(project)
                        }
                    }
                    .disabled(!canConfirm)
                }
                #if os(iOS)
                ToolbarItem(placement: .secondaryAction) { EditButton() }
                #endif
            }
            .onChange(of: draft) { _, updated in
                var saved = updated
                saved.updatedAt = ContentProgress.millisecondPrecision(Date())
                session.saveDraft(saved)
            }
            .interactiveDismissDisabled()
        }
    }

    private var canConfirm: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        draft.units.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private struct ProgressLockSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lock = AppLockController.shared

    var body: some View {
        NavigationStack {
            Form {
                Toggle("启用应用锁定", isOn: Binding(
                    get: { lock.isEnabled },
                    set: { lock.setEnabled($0) }
                ))
            }
            .navigationTitle("应用锁定")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

private struct LegacyJournalHostView: View {
    @StateObject private var session: JournalApplicationSession

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        _session = StateObject(wrappedValue: JournalApplicationSession(documentsDirectory: documents))
    }

    var body: some View {
        Group {
            if let pending = session.pendingMigration {
                MigrationReviewView(
                    dryRun: pending,
                    onContinue: { session.continueMigration() },
                    onStatusResolution: { id, resolution in
                        session.resolveArchivedProject(projectID: id, resolution: resolution)
                    },
                    onProofResolution: { id, resolution in
                        session.resolveProof(proofID: id, resolution: resolution)
                    },
                    onPracticeResolution: { id, resolution in
                        session.resolvePractice(routineID: id, resolution: resolution)
                    }
                )
            } else if let pending = session.pendingPlanRevisionMigration {
                PlanRevisionMigrationReviewView(
                    snapshot: session.viewModel.snapshot,
                    dryRun: pending,
                    onContinue: { survivors in
                        session.continuePlanRevisionMigration(with: survivors)
                    }
                )
            } else if let pending = session.pendingPracticeBlocksMigration {
                PracticeBlocksMigrationReviewView(
                    snapshot: session.viewModel.snapshot,
                    dryRun: pending,
                    onContinue: { resolutions in
                        session.continuePracticeBlocksMigration(with: resolutions)
                    },
                    onResolution: { id, resolution in
                        session.resolvePracticeBlocks(projectID: id, resolution: resolution)
                    }
                )
            } else if session.migrationGateBlocked {
                ContentUnavailableView {
                    Label("旧版数据迁移检查已暂停", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("旧版数据仍保留。检查问题解决后可重试。")
                } actions: {
                    Button("重试迁移检查") { session.retryMigrationGate() }
                }
            } else {
                RootView(viewModel: session.viewModel, calendarViewModel: session.calendarViewModel)
                    .id(ObjectIdentifier(session.viewModel))
            }
        }
        .navigationTitle("旧版学习记录")
        .alert("旧版数据迁移失败", isPresented: Binding(
            get: { session.migrationError != nil },
            set: { if !$0 { session.clearMigrationError() } }
        )) {
            Button("确定") { session.clearMigrationError() }
        } message: {
            Text(session.migrationError ?? "")
        }
    }
}
