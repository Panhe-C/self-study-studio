import SwiftUI

/// Field-level diff between a base plan revision and a candidate revision
/// draft (spec 11.3), plus the confirmed source records that motivated the
/// suggestion. The diff itself is computed by `PlanRevisionDiffEngine`; this
/// view only renders it.
public struct PlanRevisionDiffView: View {
    @Environment(\.dismiss) private var dismiss
    private let diff: PlanRevisionDiff
    private let sourceSessions: [LearningSession]
    private let onActivate: ((Bool) throws -> Void)?
    @State private var activationError: String?
    @State private var capacityAcknowledged = false

    public init(
        diff: PlanRevisionDiff,
        sourceSessions: [LearningSession] = [],
        onActivate: ((Bool) throws -> Void)? = nil
    ) {
        self.diff = diff
        self.sourceSessions = sourceSessions
        self.onActivate = onActivate
    }

    public var body: some View {
        Form {
            if diff.isEmpty {
                Section {
                    Text("adjustment.diff.no_changes")
                        .foregroundStyle(.secondary)
                }
            }

            if !diff.planFieldChanges.isEmpty {
                Section("adjustment.diff.plan_section") {
                    ForEach(diff.planFieldChanges, id: \.field) { change in
                        fieldChangeRow(change)
                    }
                }
            }

            if !diff.phaseChanges.isEmpty {
                Section("adjustment.diff.phases_section") {
                    ForEach(diff.phaseChanges) { change in
                        phaseRow(change)
                    }
                }
            }

            if !diff.sessionChanges.isEmpty {
                Section("adjustment.diff.sessions_section") {
                    ForEach(diff.sessionChanges) { change in
                        sessionRow(change)
                    }
                }
            }

            if !sourceSessions.isEmpty {
                Section("adjustment.diff.sources_section") {
                    ForEach(sourceSessions) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.note)
                                .font(.subheadline)
                                .lineLimit(3)
                            if let assessment = session.assessment {
                                Text(
                                    assessment.confirmedAt.formatted(
                                        date: .abbreviated, time: .shortened
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if let onActivate {
                Section("adjustment.diff.activation_section") {
                    Toggle("adjustment.diff.capacity_reviewed", isOn: $capacityAcknowledged)
                    Button {
                        do {
                            try onActivate(capacityAcknowledged)
                            dismiss()
                        } catch {
                            activationError = error.localizedDescription
                        }
                    } label: {
                        Label("adjustment.activate_revision", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!capacityAcknowledged)
                    Text("Review the non-empty diff and enable this revision when it matches your intent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(Text("adjustment.diff.title"))
        .alert("Could not activate revision", isPresented: .constant(activationError != nil)) {
            Button("OK") { activationError = nil }
        } message: {
            Text(activationError ?? "")
        }
    }

    private func fieldChangeRow(_ change: PlanRevisionDiff.FieldChange) -> some View {
        LabeledContent(
            PlanRevisionDiffCopy.label(for: change.field),
            value: "\(change.base ?? PlanRevisionDiffCopy.emptyValue) → \(change.candidate ?? PlanRevisionDiffCopy.emptyValue)"
        )
    }

    private func phaseRow(_ change: PlanRevisionDiff.PhaseChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(change.title, systemImage: changeKindSymbol(change.kind))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(changeKindColor(change.kind))
            Text(changeKindTitle(change.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(change.fieldChanges, id: \.field) { fieldChange in
                fieldChangeRow(fieldChange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func sessionRow(_ change: PlanRevisionDiff.SessionChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(change.title, systemImage: changeKindSymbol(change.kind))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(changeKindColor(change.kind))
            Text(changeKindTitle(change.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(change.fieldChanges, id: \.field) { fieldChange in
                fieldChangeRow(fieldChange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func changeKindSymbol(_ kind: PlanRevisionDiff.ChildChangeKind) -> String {
        switch kind {
        case .added: return "plus.circle"
        case .removed: return "minus.circle"
        case .changed: return "pencil.circle"
        }
    }

    private func changeKindColor(_ kind: PlanRevisionDiff.ChildChangeKind) -> Color {
        switch kind {
        case .added: return StudioTheme.completed
        case .removed: return StudioTheme.notice
        case .changed: return StudioTheme.accent
        }
    }

    private func changeKindTitle(_ kind: PlanRevisionDiff.ChildChangeKind) -> String {
        switch kind {
        case .added: return String(localized: "adjustment.diff.added")
        case .removed: return String(localized: "adjustment.diff.removed")
        case .changed: return String(localized: "adjustment.diff.changed")
        }
    }
}

/// Localized labels for the diff field identifiers produced by
/// `PlanRevisionDiffEngine`. Unknown fields fall back to their raw name so a
/// new diffed field never renders blank.
public enum PlanRevisionDiffCopy {
    public static var emptyValue: String {
        String(localized: "adjustment.diff.value.empty")
    }

    public static func label(for field: String) -> String {
        switch field {
        case "courseTitle": return String(localized: "adjustment.diff.field.course_title")
        case "goal": return String(localized: "adjustment.diff.field.goal")
        case "expectedOutcome": return String(localized: "adjustment.diff.field.expected_outcome")
        case "summary": return String(localized: "adjustment.diff.field.summary")
        case "startsOn": return String(localized: "adjustment.diff.field.starts_on")
        case "deadline": return String(localized: "adjustment.diff.field.deadline")
        case "weeklyBudgetMinutes": return String(localized: "adjustment.diff.field.weekly_budget")
        case "title": return String(localized: "adjustment.diff.field.title")
        case "objective": return String(localized: "adjustment.diff.field.objective")
        case "expectedProof": return String(localized: "adjustment.diff.field.expected_proof")
        case "targetStart": return String(localized: "adjustment.diff.field.target_start")
        case "targetEnd": return String(localized: "adjustment.diff.field.target_end")
        case "durationMinutes": return String(localized: "adjustment.diff.field.duration_minutes")
        case "completionCriteria": return String(localized: "adjustment.diff.field.completion_criteria")
        default: return field
        }
    }
}
