import SwiftUI

public struct ScheduleDraftView: View {
    @ObservedObject private var viewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var errorMessage: String?

    public init(viewModel: CalendarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let changes = viewModel.pendingChangeSet {
                    confirmationList(changes)
                } else {
                    draftList
                }
            }
            .navigationTitle(viewModel.pendingChangeSet == nil ? "Schedule Draft" : "Calendar Changes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Calendar unavailable", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var draftList: some View {
        List {
            if let draft = viewModel.scheduleDraft {
                Section("Placements") {
                    ForEach(draft.placements) { placement in
                        placementRow(placement)
                    }
                }

                if !draft.conflicts.isEmpty {
                    Section("Conflicts") {
                        ForEach(draft.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title(for: conflict.sessionID))
                                    .font(.headline)
                                Text(conflict.reason.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                                Text(conflict.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !draft.unscheduledSessionIDs.isEmpty {
                    Section("Unscheduled") {
                        ForEach(draft.unscheduledSessionIDs, id: \.self) { id in
                            Label(title(for: id), systemImage: "calendar.badge.exclamationmark")
                        }
                    }
                }

                Section {
                    Button {
                        reviewChanges()
                    } label: {
                        Label("Review Calendar Changes", systemImage: "list.clipboard")
                    }
                    .disabled(isWorking)
                }
            } else {
                ContentUnavailableView("No Schedule Draft", systemImage: "calendar.badge.clock")
            }
        }
    }

    private func confirmationList(_ changes: CalendarChangeSet) -> some View {
        List {
            Section("Changes") {
                if changes.items.isEmpty {
                    Label("Calendar is up to date", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                ForEach(changes.items) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(title(for: change.plannedSessionID), systemImage: icon(for: change.operation))
                            .font(.headline)
                        Text(change.operation.rawValue.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(for: change.operation))
                        if let after = change.after {
                            Text(after.start.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let before = change.before {
                            Text(before.start.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let result = viewModel.lastApplyResult {
                Section("Result") {
                    LabeledContent("Succeeded", value: "\(result.succeeded.count)")
                    LabeledContent("Failed", value: "\(result.failed.count)")
                    if !result.failed.isEmpty {
                        Button {
                            retryFailures()
                        } label: {
                            Label("Retry Failed Changes", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }

            if !changes.items.isEmpty && viewModel.lastApplyResult == nil {
                Section {
                    Button {
                        confirmChanges()
                    } label: {
                        Label("Confirm Calendar Changes", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(isWorking)
                }
            }
        }
    }

    private func placementRow(_ placement: ScheduledPlacement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: placement.sessionID)).font(.headline)
                    Text("\(placement.start.formatted(date: .abbreviated, time: .shortened)) · \(Int(placement.end.timeIntervalSince(placement.start) / 60)) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.setPlacementPinned(placement.sessionID, isPinned: !placement.isPinned)
                } label: {
                    Image(systemName: placement.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(placement.isPinned ? "Unpin" : "Pin")
            }
            HStack {
                Button {
                    viewModel.movePlacement(placement.sessionID, byMinutes: -15)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .help("Move earlier")

                Button {
                    viewModel.movePlacement(placement.sessionID, byMinutes: 15)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Move later")

                Stepper(
                    "\(Int(placement.end.timeIntervalSince(placement.start) / 60)) min",
                    value: Binding(
                        get: { Int(placement.end.timeIntervalSince(placement.start) / 60) },
                        set: { viewModel.resizePlacement(placement.sessionID, toMinutes: $0) }
                    ),
                    in: 15...240,
                    step: 15
                )

                Button(role: .destructive) {
                    viewModel.removePlacement(placement.sessionID)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove placement")
            }
        }
        .padding(.vertical, 3)
    }

    private func reviewChanges() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await viewModel.previewCalendarChanges()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func confirmChanges() {
        isWorking = true
        Task {
            _ = await viewModel.confirmCalendarChanges()
            isWorking = false
        }
    }

    private func retryFailures() {
        isWorking = true
        Task {
            _ = await viewModel.retryFailedChanges()
            isWorking = false
        }
    }

    private func title(for id: UUID) -> String {
        viewModel.items.first(where: { $0.plannedSessionID == id })?.title ?? "Study Session"
    }

    private func icon(for operation: CalendarChangeOperation) -> String {
        switch operation {
        case .create: "plus.circle"
        case .update: "arrow.triangle.2.circlepath"
        case .delete: "trash"
        }
    }

    private func color(for operation: CalendarChangeOperation) -> Color {
        switch operation {
        case .create: .green
        case .update: .indigo
        case .delete: .red
        }
    }
}
