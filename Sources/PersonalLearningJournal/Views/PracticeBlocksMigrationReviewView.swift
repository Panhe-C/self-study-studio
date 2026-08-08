import SwiftUI

/// Explicit B3 survivor selection for projects that still have more than one
/// active practice routine. The migration preserves every routine; choosing
/// merge combines the ordered blocks while archive keeps the selected routine
/// as the sole active owner.
public struct PracticeBlocksMigrationReviewView: View {
    private let snapshot: JournalSnapshot
    private let dryRun: PracticeBlocksMigrationDryRun
    private let onContinue: ([PracticeBlocksMigrationResolution]) -> Void
    private let onResolution: ((UUID, PracticeBlocksMigrationResolution) -> Void)?
    @State private var resolutions: [UUID: PracticeBlocksMigrationResolution] = [:]

    public init(
        snapshot: JournalSnapshot,
        dryRun: PracticeBlocksMigrationDryRun,
        onContinue: @escaping ([PracticeBlocksMigrationResolution]) -> Void,
        onResolution: ((UUID, PracticeBlocksMigrationResolution) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.dryRun = dryRun
        self.onContinue = onContinue
        self.onResolution = onResolution
    }

    public var body: some View {
        List {
            Section {
                Text("More than one active practice routine belongs to the same project. Choose the routine that stays active and how the other routine's blocks are handled. No routine is deleted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Practice Blocks Migration")
            }

            ForEach(dryRun.issues, id: \.self) { issue in
                if case let .multipleActiveRoutines(projectID, routineIDs) = issue {
                    routineResolutionSection(
                        projectID: projectID,
                        routineIDs: routineIDs
                    )
                }
            }

            Button("Continue with selected routines") {
                onContinue(Array(resolutions.values))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasCompleteSelection)
        }
        .navigationTitle("Practice Migration")
    }

    @ViewBuilder
    private func routineResolutionSection(
        projectID: UUID,
        routineIDs: [UUID]
    ) -> some View {
        let routines = snapshot.practiceRoutines
            .filter { routineIDs.contains($0.id) }
            .sorted { left, right in
                if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
        Section(projectName(for: projectID)) {
            Text("Choose the active survivor")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(routines) { routine in
                resolutionChoice(
                    projectID: projectID,
                    routine: routine
                )
            }
        }
    }

    private func resolutionChoice(
        projectID: UUID,
        routine: PracticeRoutine
    ) -> some View {
        let selectedResolution = resolutions[projectID]
        let isSelected = selectedResolution?.survivorID == routine.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    choose(projectID: projectID, resolution: .merge(survivorID: routine.id))
                } label: {
                    Label("Merge blocks", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.bordered)
                .tint(isSelected && selectedResolution == .merge(survivorID: routine.id) ? StudioTheme.accent : nil)

                Button {
                    choose(projectID: projectID, resolution: .archive(survivorID: routine.id))
                } label: {
                    Label("Archive others", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                .tint(isSelected && selectedResolution == .archive(survivorID: routine.id) ? StudioTheme.accent : nil)
            }
            .accessibilityElement(children: .contain)

            Text("\(routine.name) · \(routine.orderedBlocks.count) blocks · \(routine.targetMinutes) min")
                .font(.subheadline.weight(.medium))
                .accessibilityLabel(
                    "\(routine.name), \(routine.orderedBlocks.count) blocks, \(routine.targetMinutes) minutes, \(isSelected ? "selected" : "not selected")"
                )
            if let focus = routine.orderedBlocks.compactMap(\.focus).first {
                Text("Focus: \(focus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func choose(
        projectID: UUID,
        resolution: PracticeBlocksMigrationResolution
    ) {
        resolutions[projectID] = resolution
        onResolution?(projectID, resolution)
    }

    private func projectName(for projectID: UUID) -> String {
        snapshot.projects.first(where: { $0.id == projectID })?.name ?? "Project (projectID.uuidString.prefix(8))"
    }

    private var hasCompleteSelection: Bool {
        let projectIDs = dryRun.issues.compactMap { issue -> UUID? in
            guard case let .multipleActiveRoutines(projectID, _) = issue else { return nil }
            return projectID
        }
        return projectIDs.allSatisfy { resolutions[$0] != nil }
    }
}

private extension PracticeBlocksMigrationResolution {
    var survivorID: UUID {
        switch self {
        case let .merge(survivorID), let .archive(survivorID): survivorID
        }
    }
}
