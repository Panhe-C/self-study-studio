import XCTest
@testable import PersonalLearningJournal

final class PlanningWindowCapacityServiceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    func testPlanningWindowValidatesRangeAndExposesExplicitGranularity() throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: start))
        let window = try PlanningWindow(
            start: start,
            end: end,
            granularity: .week
        )

        XCTAssertEqual(window.start, start)
        XCTAssertEqual(window.end, end)
        XCTAssertEqual(window.granularity, .week)
        XCTAssertThrowsError(
            try PlanningWindow(start: end, end: start, granularity: .dateRange)
        ) { error in
            XCTAssertEqual(error as? PlanningWindowValidationError, .invalidRange)
        }
    }

    func testCapacityCheckAggregatesPlannedAndPracticeLoadByWeekAndProject() throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5)))
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let phaseID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let phase = try PlanPhase(
            id: phaseID,
            planId: UUID(),
            title: "Week one",
            objective: "Learn",
            expectedProof: "Notes",
            ordinal: 0,
            targetStart: start,
            targetEnd: start.addingTimeInterval(7 * 86_400),
            createdAt: start,
            updatedAt: start
        )
        let draft = CoursePlanDraft(
            title: "Plan",
            summary: "",
            phases: [
                CoursePlanDraftPhase(
                    id: "phase",
                    title: phase.title,
                    objective: phase.objective,
                    expectedProof: phase.expectedProof,
                    ordinal: 0,
                    targetStart: phase.targetStart,
                    targetEnd: phase.targetEnd
                )
            ],
            sessions: [
                CoursePlanDraftSession(
                    id: "session",
                    phaseID: "phase",
                    title: "Read",
                    actionType: .course,
                    durationMinutes: 90,
                    deadline: start.addingTimeInterval(86_400)
                )
            ]
        )
        let routine = PracticeRoutine(
            projectId: projectID,
            name: "Practice",
            symbolName: "timer",
            color: .teal,
            targetMinutes: 30,
            weekdays: [2, 4],
            createdAt: start.addingTimeInterval(-86_400),
            updatedAt: start.addingTimeInterval(-86_400)
        )
        let input = CoursePlanningInput(
            projectId: projectID,
            courseTitle: "Plan",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Notes",
            startsOn: start,
            weeklyBudgetMinutes: 90,
            preferredSessionMinutes: 45
        )
        let availability = try [2, 4].map { weekday in
            try AvailabilityRule(
                weekday: weekday,
                startMinute: 18 * 60,
                endMinute: 19 * 60,
                timeZoneIdentifier: "UTC",
                minimumSessionMinutes: 15,
                createdAt: start,
                updatedAt: start
            )
        }

        let result = CapacityCheckService(calendar: calendar).check(
            draft: draft,
            input: input,
            practiceRoutines: [routine],
            availabilityRules: availability
        )
        let week = try XCTUnwrap(result.weeks.first)

        XCTAssertEqual(week.availableMinutes, 120)
        XCTAssertEqual(week.plannedMinutes, 90)
        XCTAssertEqual(week.practiceMinutes, 60)
        XCTAssertEqual(week.totalMinutes, 150)
        XCTAssertEqual(week.overageMinutes, 30)
        XCTAssertTrue(result.isOverCapacity)
        XCTAssertTrue(result.requiresAcknowledgement)
        XCTAssertEqual(week.projectLoads.first?.projectID, projectID)
        XCTAssertEqual(week.projectLoads.first?.totalMinutes, 150)
        XCTAssertEqual(result.warnings.first?.projectIDs, [projectID])
    }

    func testCapacityCheckIsDeterministicAcrossInputPermutation() throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5)))
        let first = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            name: "B",
            area: "Test",
            goal: "Learn",
            currentNextStep: "B",
            createdAt: start,
            updatedAt: start,
            activeEvidenceContractId: UUID()
        )
        let second = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            name: "A",
            area: "Test",
            goal: "Learn",
            currentNextStep: "A",
            createdAt: start,
            updatedAt: start,
            activeEvidenceContractId: UUID()
        )
        let input = CoursePlanningInput(
            projectId: first.id,
            courseTitle: "Plan",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Notes",
            startsOn: start,
            weeklyBudgetMinutes: 60,
            preferredSessionMinutes: 30
        )
        let phase = CoursePlanDraftPhase(
            id: "phase",
            title: "Phase",
            objective: "Learn",
            expectedProof: "Notes",
            ordinal: 0,
            targetStart: start,
            targetEnd: start.addingTimeInterval(7 * 86_400)
        )
        let draft = CoursePlanDraft(
            title: "Plan",
            summary: "",
            phases: [phase],
            sessions: [
                CoursePlanDraftSession(
                    id: "session",
                    phaseID: "phase",
                    title: "Read",
                    actionType: .course,
                    durationMinutes: 30,
                    deadline: start.addingTimeInterval(86_400)
                )
            ]
        )
        let routines = [
            PracticeRoutine(
                projectId: first.id,
                name: "B routine",
                symbolName: "timer",
                color: .teal,
                targetMinutes: 15,
                weekdays: [2],
                createdAt: start,
                updatedAt: start
            ),
            PracticeRoutine(
                projectId: second.id,
                name: "A routine",
                symbolName: "timer",
                color: .teal,
                targetMinutes: 15,
                weekdays: [2],
                createdAt: start,
                updatedAt: start
            )
        ]
        let availability = [try AvailabilityRule(
            weekday: 2,
            startMinute: 18 * 60,
            endMinute: 19 * 60,
            timeZoneIdentifier: "UTC",
            minimumSessionMinutes: 15,
            createdAt: start,
            updatedAt: start
        )]
        let service = CapacityCheckService(calendar: calendar)
        let one = service.check(
            draft: draft,
            input: input,
            practiceRoutines: routines,
            availabilityRules: availability
        )
        let two = service.check(
            draft: draft,
            input: input,
            practiceRoutines: routines.reversed(),
            availabilityRules: availability.reversed()
        )

        XCTAssertEqual(one, two)
        XCTAssertEqual(one.weeks.first?.projectLoads.map(\.projectID), [first.id, second.id].sorted { $0.uuidString < $1.uuidString })
    }

    func testDSTAvailabilityUsesActualCalendarDuration() throws {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.locale = Locale(identifier: "en_US_POSIX")
        dstCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        dstCalendar.firstWeekday = 2
        let start = try XCTUnwrap(dstCalendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let projectID = UUID()
        let phase = CoursePlanDraftPhase(
            id: "phase",
            title: "DST",
            objective: "Learn",
            expectedProof: "Notes",
            ordinal: 0,
            targetStart: dstCalendar.startOfDay(for: start),
            targetEnd: try XCTUnwrap(dstCalendar.date(byAdding: .day, value: 1, to: dstCalendar.startOfDay(for: start)))
        )
        let draft = CoursePlanDraft(
            title: "DST",
            summary: "",
            phases: [phase],
            sessions: [
                CoursePlanDraftSession(
                    id: "session",
                    phaseID: "phase",
                    title: "DST work",
                    actionType: .course,
                    durationMinutes: 150
                )
            ]
        )
        let input = CoursePlanningInput(
            projectId: projectID,
            courseTitle: "DST",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Notes",
            startsOn: dstCalendar.startOfDay(for: start),
            weeklyBudgetMinutes: 150,
            preferredSessionMinutes: 30
        )
        let availability = [try AvailabilityRule(
            weekday: 1,
            startMinute: 1 * 60,
            endMinute: 4 * 60,
            timeZoneIdentifier: "America/Los_Angeles",
            minimumSessionMinutes: 15,
            createdAt: start,
            updatedAt: start
        )]

        let result = CapacityCheckService(calendar: dstCalendar).check(
            draft: draft,
            input: input,
            availabilityRules: availability
        )

        XCTAssertEqual(result.weeks.first?.availableMinutes, 120)
        XCTAssertEqual(result.weeks.first?.overageMinutes, 30)
        XCTAssertTrue(result.isOverCapacity)
    }
}
