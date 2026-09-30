import Charts
import SwiftUI

public struct ProjectTrailDay: Equatable, Identifiable, Sendable {
    public let date: Date
    public let learningMinutes: Int
    public let practiceMinutes: Int

    public var id: Date { date }
    public var totalMinutes: Int { learningMinutes + practiceMinutes }
}

public struct ProjectTrailPhase: Equatable, Identifiable, Sendable {
    public let phase: PlanPhase
    public let completedSessions: Int
    public let totalSessions: Int

    public var id: UUID { phase.id }
    public var progress: Double {
        guard totalSessions > 0 else { return phase.progress == .completed ? 1 : 0 }
        return Double(completedSessions) / Double(totalSessions)
    }
}

public struct ProjectTrailEntry: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case learning
        case practice
        case milestone
        case proof
        case review
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let detail: String
    public let occurredAt: Date
}

public struct ProjectTrailSummary: Equatable, Identifiable, Sendable {
    public let project: Project
    public let days: [ProjectTrailDay]
    public let phases: [ProjectTrailPhase]
    public let entries: [ProjectTrailEntry]
    public let learningMinutes: Int
    public let practiceMinutes: Int
    public let sessionCount: Int
    public let activeDayCount: Int

    public var id: UUID { project.id }
    public var totalMinutes: Int { learningMinutes + practiceMinutes }
    public var weeklyFrequency: Double { Double(activeDayCount) / 2 }
}

public enum ProjectTrailProjector {
    public static func project(
        snapshot: JournalSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ProjectTrailSummary] {
        snapshot.projects
            .filter { !$0.isTrashed && $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status { return statusRank(lhs.status) < statusRank(rhs.status) }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { summarize(project: $0, snapshot: snapshot, now: now, calendar: calendar) }
    }

    private static func summarize(
        project: Project,
        snapshot: JournalSnapshot,
        now: Date,
        calendar: Calendar
    ) -> ProjectTrailSummary {
        let sessions = snapshot.sessions.filter {
            $0.projectId == project.id && $0.deletedAt == nil
        }
        let mirroredIDs = Set(snapshot.sessions.map(\.id))
        let standalonePractice = snapshot.practiceSessions.filter {
            $0.linkedProjectId == project.id && $0.deletedAt == nil && !mirroredIDs.contains($0.id)
        }
        let endDay = calendar.startOfDay(for: now)
        let startDay = calendar.date(byAdding: .day, value: -13, to: endDay) ?? endDay

        var learningByDay: [Date: Int] = [:]
        var practiceByDay: [Date: Int] = [:]
        for session in sessions where session.endedAt >= startDay {
            let day = calendar.startOfDay(for: session.endedAt)
            if session.actionType == .practice {
                practiceByDay[day, default: 0] += session.durationMinutes
            } else {
                learningByDay[day, default: 0] += session.durationMinutes
            }
        }
        for session in standalonePractice where session.endedAt >= startDay {
            let day = calendar.startOfDay(for: session.endedAt)
            practiceByDay[day, default: 0] += roundedMinutes(session.activeDurationSeconds)
        }

        let days = (0..<14).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: startDay) ?? startDay
            return ProjectTrailDay(
                date: date,
                learningMinutes: learningByDay[date, default: 0],
                practiceMinutes: practiceByDay[date, default: 0]
            )
        }
        let phases = phaseProgress(project: project, snapshot: snapshot)
        let entries = timeline(
            project: project,
            sessions: sessions,
            standalonePractice: standalonePractice,
            trailEvents: snapshot.trailEvents
        )
        return ProjectTrailSummary(
            project: project,
            days: days,
            phases: phases,
            entries: entries,
            learningMinutes: sessions.filter { $0.actionType != .practice }.reduce(0) { $0 + $1.durationMinutes },
            practiceMinutes: sessions.filter { $0.actionType == .practice }.reduce(0) { $0 + $1.durationMinutes }
                + standalonePractice.reduce(0) { $0 + roundedMinutes($1.activeDurationSeconds) },
            sessionCount: sessions.count + standalonePractice.count,
            activeDayCount: days.count { $0.totalMinutes > 0 }
        )
    }

    private static func phaseProgress(
        project: Project,
        snapshot: JournalSnapshot
    ) -> [ProjectTrailPhase] {
        let plan = snapshot.learningPlanAggregates(for: project.id)
            .compactMap(\.activeRevision)
            .first?.plan
            ?? project.activeCoursePlanId.flatMap { id in snapshot.coursePlans.first { $0.id == id } }
        guard let plan else { return [] }
        return snapshot.planPhases
            .filter { $0.planId == plan.id && $0.deletedAt == nil }
            .sorted { $0.ordinal < $1.ordinal }
            .map { phase in
                let planned = snapshot.plannedSessions.filter {
                    $0.phaseId == phase.id && $0.deletedAt == nil
                }
                return ProjectTrailPhase(
                    phase: phase,
                    completedSessions: planned.count { $0.status == .completed },
                    totalSessions: planned.count
                )
            }
    }

    private static func timeline(
        project: Project,
        sessions: [LearningSession],
        standalonePractice: [PracticeSession],
        trailEvents: [TrailEvent]
    ) -> [ProjectTrailEntry] {
        let sessionEntries = sessions.map { session in
            ProjectTrailEntry(
                id: session.id,
                kind: session.actionType == .practice ? .practice : .learning,
                title: session.actionType == .practice
                    ? String(localized: "trail.entry.practice")
                    : String(localized: "trail.entry.learning"),
                detail: session.note,
                occurredAt: session.endedAt
            )
        }
        let practiceEntries = standalonePractice.map { session in
            ProjectTrailEntry(
                id: session.id,
                kind: .practice,
                title: String(localized: "trail.entry.practice"),
                detail: session.note ?? String(localized: "trail.entry.practice_completed"),
                occurredAt: session.endedAt
            )
        }
        let eventEntries = trailEvents
            .filter { $0.projectId == project.id && $0.deletedAt == nil && $0.type != .session }
            .map { event in
                ProjectTrailEntry(
                    id: event.id,
                    kind: entryKind(event.type),
                    title: event.title,
                    detail: event.detail,
                    occurredAt: event.occurredAt
                )
            }
        return (sessionEntries + practiceEntries + eventEntries)
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(30)
            .map { $0 }
    }

    private static func entryKind(_ type: TrailEventType) -> ProjectTrailEntry.Kind {
        switch type {
        case .proof: .proof
        case .review: .review
        case .session: .learning
        case .statusChange, .nextStepChange, .planActivated, .planRevised, .scheduleChanged, .calendarSynced:
            .milestone
        }
    }

    private static func roundedMinutes(_ seconds: Int) -> Int {
        guard seconds > 0 else { return 0 }
        return max(1, Int((Double(seconds) / 60).rounded()))
    }

    private static func statusRank(_ status: ProjectStatus) -> Int {
        switch status {
        case .active, .lowFrequency: 0
        case .idea: 1
        case .paused: 2
        case .completed: 3
        case .abandoned: 4
        case .archived, .trash: 5
        }
    }
}

public struct ProjectTrailView: View {
    @ObservedObject private var viewModel: JournalViewModel
    @State private var selectedProjectID: UUID?

    public init(viewModel: JournalViewModel) {
        self.viewModel = viewModel
    }

    private var summaries: [ProjectTrailSummary] {
        ProjectTrailProjector.project(snapshot: viewModel.snapshot)
    }

    private var selectedSummary: ProjectTrailSummary? {
        summaries.first { $0.id == selectedProjectID } ?? summaries.first
    }

    public var body: some View {
        ScrollView {
            if let summary = selectedSummary {
                LazyVStack(alignment: .leading, spacing: StudioTheme.sectionSpacing) {
                    projectPicker(summary)
                    overview(summary)
                    rhythm(summary)
                    phases(summary)
                    timeline(summary)
                }
                .padding(.horizontal, StudioTheme.pageInset)
                .padding(.vertical, 12)
            } else {
                ContentUnavailableView(
                    String(localized: "trail.empty.title"),
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    description: Text("trail.empty.detail")
                )
                .padding(.top, 64)
            }
        }
        .background(StudioTheme.pageBackground.ignoresSafeArea())
        .navigationTitle(Text("trail.title"))
        .onAppear { selectFirstProjectIfNeeded() }
        .onChange(of: summaries.map(\.id)) { _, _ in selectFirstProjectIfNeeded() }
    }

    private func projectPicker(_ summary: ProjectTrailSummary) -> some View {
        Menu {
            ForEach(summaries) { item in
                Button {
                    selectedProjectID = item.id
                } label: {
                    if item.id == summary.id {
                        Label(item.project.name, systemImage: "checkmark")
                    } else {
                        Text(item.project.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(StudioTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("trail.project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary.project.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func overview(_ summary: ProjectTrailSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metric(String(localized: "trail.total_time"), StudioDurationFormat.compact(seconds: summary.totalMinutes * 60), "clock.fill", StudioTheme.accent)
            metric(String(localized: "trail.frequency"), String(format: "%.1f×", summary.weeklyFrequency), "calendar.badge.clock", StudioTheme.completed)
            metric(String(localized: "trail.learning"), "\(summary.learningMinutes) min", "book.fill", StudioTheme.accent)
            metric(String(localized: "trail.practice"), "\(summary.practiceMinutes) min", "repeat.circle.fill", StudioTheme.completed)
        }
    }

    private func metric(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func rhythm(_ summary: ProjectTrailSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSectionHeader(title: String(localized: "trail.rhythm"))
            HStack(spacing: 16) {
                Label("trail.learning", systemImage: "circle.fill").foregroundStyle(StudioTheme.accent)
                Label("trail.practice", systemImage: "circle.fill").foregroundStyle(StudioTheme.completed)
            }
            .font(.caption)
            Chart(summary.days) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    yStart: .value("Start", 0),
                    yEnd: .value("Learning", day.learningMinutes)
                )
                .foregroundStyle(StudioTheme.accent)
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    yStart: .value("Start", day.learningMinutes),
                    yEnd: .value("Total", day.totalMinutes)
                )
                .foregroundStyle(StudioTheme.completed)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func phases(_ summary: ProjectTrailSummary) -> some View {
        if !summary.phases.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionHeader(title: String(localized: "trail.phases"))
                ForEach(summary.phases) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.phase.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(item.completedSessions)/\(item.totalSessions)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: item.progress).tint(StudioTheme.completed)
                        Text(item.phase.objective)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func timeline(_ summary: ProjectTrailSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioSectionHeader(title: String(localized: "trail.timeline"))
            if summary.entries.isEmpty {
                Text("trail.timeline.empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                ForEach(summary.entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(entry.kind))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(color(entry.kind))
                            .background(color(entry.kind).opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(entry.occurredAt, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if !entry.detail.isEmpty {
                                Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func icon(_ kind: ProjectTrailEntry.Kind) -> String {
        switch kind {
        case .learning: "book.fill"
        case .practice: "repeat"
        case .milestone: "flag.fill"
        case .proof: "checkmark.seal.fill"
        case .review: "text.magnifyingglass"
        }
    }

    private func color(_ kind: ProjectTrailEntry.Kind) -> Color {
        switch kind {
        case .learning: StudioTheme.accent
        case .practice: StudioTheme.completed
        case .milestone: .orange
        case .proof: .purple
        case .review: .indigo
        }
    }

    private func selectFirstProjectIfNeeded() {
        if !summaries.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = summaries.first?.id
        }
    }
}
