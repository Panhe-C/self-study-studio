import XCTest
@testable import PersonalLearningJournal

final class TodayAgendaServiceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    func testAgendaIsDeterministicAndCombinesPlannedPracticeAndNextStep() throws {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10)))
        var plannedProject = activeProject(name: "Planned", createdAt: day.addingTimeInterval(-300))
        let practiceProject = activeProject(name: "Practice", createdAt: day.addingTimeInterval(-200))
        let nextStepProject = activeProject(name: "Next", createdAt: day.addingTimeInterval(-100))
        let plan = try makePlan(projectID: plannedProject.id, startsOn: day.addingTimeInterval(-86_400))
        plannedProject.activeCoursePlanId = plan.id
        let phase = try makePhase(plan: plan, targetStart: day.addingTimeInterval(-86_400), targetEnd: day.addingTimeInterval(86_400))
        let planned = try PlannedSession(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            phaseId: phase.id,
            projectId: plannedProject.id,
            title: "Ship the outline",
            actionType: .course,
            durationMinutes: 30,
            deadline: day.addingTimeInterval(3_600),
            status: .scheduled,
            createdAt: day.addingTimeInterval(-60),
            updatedAt: day.addingTimeInterval(-60)
        )
        let routine = PracticeRoutine(
            projectId: practiceProject.id,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 20,
            weekdays: [2],
            createdAt: day.addingTimeInterval(-86_400),
            updatedAt: day.addingTimeInterval(-86_400)
        )
        let snapshot = JournalSnapshot(
            projects: [nextStepProject, practiceProject, plannedProject],
            coursePlans: [plan],
            planPhases: [phase],
            plannedSessions: [planned],
            practiceRoutines: [routine]
        )
        let service = TodayAgendaService(calendar: calendar)

        let first = service.agenda(snapshot: snapshot, day: day, now: day)
        let second = service.agenda(
            snapshot: JournalSnapshot(
                projects: [plannedProject, practiceProject, nextStepProject],
                coursePlans: [plan],
                planPhases: [phase],
                plannedSessions: [planned],
                practiceRoutines: [routine]
            ),
            day: day,
            now: day
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.items.map(\.source),
            [.plannedSession, .practiceRoutine, .nextStep, .nextStep, .nextStep]
        )
        XCTAssertEqual(first.items.first?.position, .upNext)
        XCTAssertEqual(
            first.items.map(\.projectID),
            [plannedProject.id, practiceProject.id, plannedProject.id, practiceProject.id, nextStepProject.id]
        )
        XCTAssertTrue(first.items.allSatisfy { $0.carryover == nil })
    }

    func testInputPermutationKeepsDefaultUpNextAndIncludesOneNextStepPerProject() throws {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10)))
        var plannedProject = activeProject(name: "Zeta", createdAt: day.addingTimeInterval(-100))
        let plainProject = activeProject(name: "Alpha", createdAt: day.addingTimeInterval(-100))
        let plan = try makePlan(projectID: plannedProject.id, startsOn: day.addingTimeInterval(-86_400))
        plannedProject.activeCoursePlanId = plan.id
        let phase = try makePhase(
            plan: plan,
            targetStart: day.addingTimeInterval(-86_400),
            targetEnd: day.addingTimeInterval(86_400)
        )
        let planned = try PlannedSession(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            phaseId: phase.id,
            projectId: plannedProject.id,
            title: "Zeta planned",
            actionType: .course,
            durationMinutes: 30,
            deadline: day.addingTimeInterval(3_600),
            status: .scheduled,
            createdAt: day.addingTimeInterval(-60),
            updatedAt: day.addingTimeInterval(-60)
        )
        let routine = PracticeRoutine(
            projectId: plannedProject.id,
            name: "Zeta practice",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 20,
            weekdays: [2],
            createdAt: day.addingTimeInterval(-86_400),
            updatedAt: day.addingTimeInterval(-86_400)
        )
        let snapshot = JournalSnapshot(
            projects: [plainProject, plannedProject],
            coursePlans: [plan],
            planPhases: [phase],
            plannedSessions: [planned],
            practiceRoutines: [routine]
        )
        let permuted = JournalSnapshot(
            projects: [plannedProject, plainProject],
            coursePlans: [plan],
            planPhases: [phase],
            plannedSessions: [planned],
            practiceRoutines: [routine]
        )
        let service = TodayAgendaService(calendar: calendar)

        let first = service.agenda(snapshot: snapshot, day: day, now: day)
        let second = service.agenda(snapshot: permuted, day: day, now: day)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.items.first?.source, .plannedSession)
        XCTAssertEqual(first.items.first?.position, .upNext)
        XCTAssertEqual(first.items.filter { $0.source == .nextStep }.count, 2)
        XCTAssertEqual(
            Set(first.items.filter { $0.source == .nextStep }.map(\.projectID)),
            Set([plannedProject.id, plainProject.id])
        )
    }

    func testLatestUpNextOverrideWinsExclusivelyAndSkipRemainsSkip() throws {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10)))
        let first = activeProject(name: "First", createdAt: day.addingTimeInterval(-300))
        let second = activeProject(name: "Second", createdAt: day.addingTimeInterval(-200))
        let third = activeProject(name: "Third", createdAt: day.addingTimeInterval(-100))
        let snapshot = JournalSnapshot(projects: [third, first, second])
        let overrides = [
            TodayAgendaOverride(day: day, source: .nextStep, sourceID: first.id, position: .upNext),
            TodayAgendaOverride(day: day, source: .nextStep, sourceID: second.id, position: .skipToday),
            TodayAgendaOverride(day: day, source: .nextStep, sourceID: first.id, position: .upNext),
            TodayAgendaOverride(day: day, source: .nextStep, sourceID: third.id, position: .upNext)
        ]

        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: snapshot,
            day: day,
            now: day,
            overrides: overrides
        )

        XCTAssertEqual(agenda.items.first?.sourceID, third.id)
        XCTAssertEqual(agenda.items.filter { $0.position == .upNext }.count, 1)
        XCTAssertEqual(agenda.items.first(where: { $0.sourceID == first.id })?.position, .optional)
        XCTAssertEqual(agenda.items.first(where: { $0.sourceID == second.id })?.position, .skipToday)
    }

    func testRoutineCreatedAtAtDayEndIsExcludedByHalfOpenDayBoundary() throws {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10)))
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let project = activeProject(name: "Boundary", createdAt: day.addingTimeInterval(-100))
        let atBoundary = PracticeRoutine(
            projectId: project.id,
            name: "Created at next day",
            symbolName: "timer",
            color: .teal,
            targetMinutes: 20,
            weekdays: [2],
            createdAt: dayEnd,
            updatedAt: dayEnd
        )
        let justBeforeBoundary = PracticeRoutine(
            projectId: project.id,
            name: "Created before next day",
            symbolName: "timer",
            color: .teal,
            targetMinutes: 20,
            weekdays: [2],
            createdAt: dayEnd.addingTimeInterval(-1),
            updatedAt: dayEnd.addingTimeInterval(-1)
        )

        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: JournalSnapshot(
                projects: [project],
                practiceRoutines: [atBoundary, justBeforeBoundary]
            ),
            day: day,
            now: day
        )

        XCTAssertFalse(agenda.items.contains { $0.sourceID == atBoundary.id })
        XCTAssertTrue(agenda.items.contains { $0.sourceID == justBeforeBoundary.id })
    }

    func testDSTCalendarUsesCalendarDayEndForAgendaAndCreatedAtBoundary() throws {
        var dstCalendar = calendar
        dstCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let day = try XCTUnwrap(dstCalendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let dayStart = dstCalendar.startOfDay(for: day)
        let dayEnd = try XCTUnwrap(dstCalendar.date(byAdding: .day, value: 1, to: dayStart))
        XCTAssertEqual(dayEnd.timeIntervalSince(dayStart), 23 * 60 * 60)

        var project = activeProject(name: "DST", createdAt: dayStart.addingTimeInterval(-100))
        let plan = try makePlan(projectID: project.id, startsOn: dayStart)
        project.activeCoursePlanId = plan.id
        let phase = try makePhase(plan: plan, targetStart: dayStart, targetEnd: dayEnd)
        let planned = try PlannedSession(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            phaseId: phase.id,
            projectId: project.id,
            title: "DST session",
            actionType: .course,
            durationMinutes: 30,
            deadline: dayEnd.addingTimeInterval(-1),
            status: .scheduled,
            createdAt: dayStart,
            updatedAt: dayStart
        )
        let boundaryRoutine = PracticeRoutine(
            projectId: project.id,
            name: "DST boundary routine",
            symbolName: "timer",
            color: .teal,
            targetMinutes: 20,
            weekdays: [dstCalendar.component(.weekday, from: dayStart)],
            createdAt: dayEnd,
            updatedAt: dayEnd
        )

        let agenda = TodayAgendaService(calendar: dstCalendar).agenda(
            snapshot: JournalSnapshot(
                projects: [project],
                coursePlans: [plan],
                planPhases: [phase],
                plannedSessions: [planned],
                practiceRoutines: [boundaryRoutine]
            ),
            day: day,
            now: day
        )

        XCTAssertTrue(agenda.items.contains { $0.sourceID == planned.id })
        XCTAssertFalse(agenda.items.contains { $0.sourceID == boundaryRoutine.id })
    }

    func testMissedPlannedSessionBecomesCarryoverWithoutMovingItsWindow() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        var project = activeProject(name: "Carry", createdAt: yesterday.addingTimeInterval(-100))
        let plan = try makePlan(projectID: project.id, startsOn: yesterday.addingTimeInterval(-86_400))
        project.activeCoursePlanId = plan.id
        let phase = try makePhase(plan: plan, targetStart: yesterday.addingTimeInterval(-86_400), targetEnd: yesterday)
        let planned = try PlannedSession(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            phaseId: phase.id,
            projectId: project.id,
            title: "Missed reading",
            actionType: .reading,
            durationMinutes: 25,
            deadline: yesterday.addingTimeInterval(-3_600),
            status: .scheduled,
            createdAt: yesterday.addingTimeInterval(-100),
            updatedAt: yesterday.addingTimeInterval(-100)
        )
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: JournalSnapshot(projects: [project], coursePlans: [plan], planPhases: [phase], plannedSessions: [planned]),
            day: today,
            now: today
        )
        let item = try XCTUnwrap(agenda.items.first)

        XCTAssertEqual(item.source, .plannedSession)
        XCTAssertEqual(item.sourceID, planned.id)
        XCTAssertEqual(item.windowStart, phase.targetStart)
        XCTAssertEqual(item.windowEnd, planned.deadline)
        XCTAssertEqual(item.carryover?.originalDeadline, planned.deadline)
        XCTAssertEqual(item.carryover?.originalWindowStart, item.windowStart)
        XCTAssertEqual(item.carryover?.originalWindowEnd, item.windowEnd)
        XCTAssertEqual(item.carryover?.reason, .planningWindowPassed)
        XCTAssertEqual(item.carryover?.resolutions, TodayCarryoverResolution.allCases)
    }

    func testMissedPracticeIsOnlyACadenceSignalAndNeverCarryover() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let project = activeProject(name: "Practice", createdAt: yesterday.addingTimeInterval(-100))
        let routine = PracticeRoutine(
            projectId: project.id,
            name: "Guitar",
            symbolName: "guitars",
            color: .teal,
            targetMinutes: 20,
            weekdays: [1],
            createdAt: yesterday.addingTimeInterval(-86_400),
            updatedAt: yesterday.addingTimeInterval(-86_400)
        )
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: JournalSnapshot(projects: [project], practiceRoutines: [routine]),
            day: today,
            now: today
        )

        XCTAssertFalse(agenda.items.contains { $0.source == .practiceRoutine && $0.carryover != nil })
        XCTAssertTrue(agenda.cadenceSignals.contains { $0.routineID == routine.id && $0.isMissed })
    }

    func testDailyOverrideRepositionsOnlyTheProjection() throws {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10)))
        let first = activeProject(name: "First", createdAt: day.addingTimeInterval(-200))
        let second = activeProject(name: "Second", createdAt: day.addingTimeInterval(-100))
        let snapshot = JournalSnapshot(projects: [first, second])
        let service = TodayAgendaService(calendar: calendar)
        let before = service.agenda(snapshot: snapshot, day: day, now: day)
        let target = try XCTUnwrap(before.items.last)
        let override = TodayAgendaOverride(day: day, source: target.source, sourceID: target.sourceID, position: .skipToday)
        let after = service.agenda(snapshot: snapshot, day: day, now: day, overrides: [override])

        XCTAssertEqual(snapshot, JournalSnapshot(projects: [first, second]))
        XCTAssertEqual(after.items.first(where: { $0.sourceID == target.sourceID })?.position, .skipToday)
        XCTAssertTrue(after.items.filter { $0.position != .skipToday }.allSatisfy { $0.position == .upNext || $0.position == .optional || $0.position == .laterToday })
    }

    func testEmptyAgendaIsExplicit() throws {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10)))
        let agenda = TodayAgendaService(calendar: calendar).agenda(snapshot: JournalSnapshot(), day: day, now: day)

        XCTAssertTrue(agenda.items.isEmpty)
        XCTAssertTrue(agenda.cadenceSignals.isEmpty)
    }

    private func activeProject(name: String, createdAt: Date) -> Project {
        Project(
            name: name,
            area: "Test",
            goal: "Learn",
            currentNextStep: "Take one small step",
            createdAt: createdAt,
            updatedAt: createdAt,
            activeEvidenceContractId: UUID()
        )
    }

    private func makePlan(projectID: UUID, startsOn: Date) throws -> LearningPlan {
        try LearningPlan(
            projectId: projectID,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Plan",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Outcome",
            startsOn: startsOn,
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "",
            createdAt: startsOn,
            updatedAt: startsOn
        )
    }

    private func makePhase(plan: LearningPlan, targetStart: Date, targetEnd: Date) throws -> PlanPhase {
        try PlanPhase(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            title: "Phase",
            objective: "Objective",
            expectedProof: "Proof",
            ordinal: 0,
            targetStart: targetStart,
            targetEnd: targetEnd,
            createdAt: targetStart,
            updatedAt: targetStart
        )
    }
}
