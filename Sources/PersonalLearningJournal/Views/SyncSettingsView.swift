import SwiftUI

public struct SyncSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var appLock: AppLockController
    @State private var notice: SyncSettingsNotice?
    @State private var isSyncing = false
    @State private var showingBootstrapConfirmation = false

    public init(viewModel: JournalViewModel, appLock: AppLockController = .shared) {
        self.viewModel = viewModel
        self.appLock = appLock
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Personal iCloud") {
                    LabeledContent("Account", value: accountDescription)
                    LabeledContent("Status", value: viewModel.syncSummary.title)
                    LabeledContent("Pending", value: "\(viewModel.syncPendingMutationCount)")
                    if let lastSuccess = viewModel.syncLastSuccess {
                        LabeledContent("Last synced", value: lastSuccess.formatted(date: .abbreviated, time: .shortened))
                    }

                    Button {
                        Task { await retrySync() }
                    } label: {
                        Label(isSyncing ? "Syncing" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isSyncing || !canSync)

                    Text(viewModel.syncSummary.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if viewModel.bootstrapEntityCount > 0 {
                    Section("Existing Learning Data") {
                        Text("\(viewModel.bootstrapEntityCount) existing item\(viewModel.bootstrapEntityCount == 1 ? "" : "s") can be added to your personal iCloud journal.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Choose Transfer") {
                            showingBootstrapConfirmation = true
                        }
                    }
                }

                Section("Conflict Review") {
                    if viewModel.syncConflicts.isEmpty {
                        Label("No unresolved conflicts", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.syncConflicts) { conflict in
                            NavigationLink {
                                SyncConflictDetailView(viewModel: viewModel, conflict: conflict)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conflict.entity.kind.rawValue.capitalized)
                                        .font(.headline)
                                    Text(conflict.conflictingFields.joined(separator: ", "))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Privacy") {
                    Toggle("Require Device Unlock", isOn: Binding(
                        get: { appLock.isEnabled },
                        set: { appLock.setEnabled($0) }
                    ))
                    Text("When enabled, protected screens are covered whenever the app leaves the foreground.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("iCloud Sync")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await viewModel.refreshSyncSummary() }
            .confirmationDialog(
                "Transfer existing learning data?",
                isPresented: $showingBootstrapConfirmation,
                titleVisibility: .visible
            ) {
                Button("Copy \(viewModel.bootstrapEntityCount) Items") { transferExistingData(.copy) }
                Button("Move \(viewModel.bootstrapEntityCount) Items", role: .destructive) { transferExistingData(.move) }
                Button("Keep Local") { transferExistingData(.keepLocal) }
            } message: {
                Text("A recovery archive is created first. Copy preserves the local space; Move removes it only after the account copy is committed.")
            }
            .alert(item: $notice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var canSync: Bool {
        switch viewModel.syncAccountState.mode {
        case .cloud:
            true
        case .checking, .localOnly, .restricted, .unavailable:
            false
        }
    }

    private var accountDescription: String {
        switch viewModel.syncAccountState.mode {
        case .checking:
            "Checking iCloud"
        case .localOnly:
            "Local only"
        case .cloud:
            "Personal iCloud"
        case .restricted:
            "iCloud restricted"
        case .unavailable:
            "iCloud unavailable"
        }
    }

    private func retrySync() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await viewModel.syncNow()
        } catch {
            notice = SyncSettingsNotice(title: "Sync Failed", message: error.localizedDescription)
        }
    }

    private func transferExistingData(_ choice: AccountSpaceTransferChoice) {
        do {
            try viewModel.completeAccountSpaceTransfer(choice: choice)
            Task { await viewModel.refreshSyncSummary() }
        } catch {
            notice = SyncSettingsNotice(title: "Transfer Not Completed", message: error.localizedDescription)
        }
    }
}

private struct SyncConflictDetailView: View {
    @ObservedObject var viewModel: JournalViewModel
    let conflict: SyncConflict
    @State private var mergedPayload: String
    @State private var notice: SyncSettingsNotice?

    init(viewModel: JournalViewModel, conflict: SyncConflict) {
        self.viewModel = viewModel
        self.conflict = conflict
        _mergedPayload = State(initialValue: Self.formattedJSON(conflict.proposedPayload))
    }

    var body: some View {
        List {
            Section("Conflicting Fields") {
                ForEach(conflict.conflictingFields, id: \.self) { field in
                    Text(field)
                }
            }

            payloadSection("Base", payload: conflict.basePayload)
            payloadSection("On This Device", payload: conflict.localPayload)
            payloadSection("In iCloud", payload: conflict.serverPayload)

            Section("Edited Merge") {
                TextEditor(text: $mergedPayload)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 180)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
            }

            Section("Resolve With") {
                Button("Use Local Version") { resolve(using: conflict.localPayload) }
                Button("Use Cloud Version") { resolve(using: conflict.serverPayload) }
                Button("Save Edited Merge") { resolveEdited() }
            }
        }
        .navigationTitle("Resolve Conflict")
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private func payloadSection(_ title: String, payload: Data) -> some View {
        Section(title) {
            Text(Self.formattedJSON(payload))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func resolve(using payload: Data) {
        do {
            try viewModel.resolveSyncConflict(id: conflict.id, using: payload)
        } catch {
            notice = SyncSettingsNotice(title: "Conflict Not Resolved", message: error.localizedDescription)
        }
    }

    private func resolveEdited() {
        guard let data = mergedPayload.data(using: .utf8) else { return }
        resolve(using: data)
    }

    private static func formattedJSON(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: formatted, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? "Invalid payload"
        }
        return text
    }
}

private struct SyncSettingsNotice: Identifiable {
    var id = UUID()
    var title: String
    var message: String
}
