import XCTest
@testable import PersonalLearningJournal

final class ProjectTrailAndCoachTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTrailSeparatesLearningAndPracticeWithoutDoubleCountingMirroredPractice() throws {
        let project = Project(
            name: "Guitar",
            area: "Music",
            goal: "Improvise",
            status: .active,
            currentNextStep: "Practice triads"
        )
        let learning = try LearningSession(
            projectId: project.id,
            source: .timer,
            actionType: .course,
            startedAt: now.addingTimeInterval(-3_600),
            endedAt: now.addingTimeInterval(-1_800),
            durationMinutes: 30,
            note: "Learned triad shapes",
            nextStepBefore: "",
            nextStepAfter: "Practice triads"
        )
        let practiceID = UUID()
        let practice = try LearningSession(
            id: practiceID,
            projectId: project.id,
            source: .timer,
            actionType: .practice,
            startedAt: now.addingTimeInterval(-1_500),
            endedAt: now,
            durationMinutes: 25,
            note: "Changed between triads",
            nextStepBefore: "Practice triads",
            nextStepAfter: "Practice triads"
        )
        let mirroredPractice = PracticeSession(
            id: practiceID,
            routineId: UUID(),
            linkedProjectId: project.id,
            startedAt: practice.startedAt,
            endedAt: practice.endedAt,
            activeDurationSeconds: 1_500
        )

        let summary = try XCTUnwrap(ProjectTrailProjector.project(
            snapshot: JournalSnapshot(
                projects: [project],
                sessions: [learning, practice],
                practiceSessions: [mirroredPractice]
            ),
            now: now,
            calendar: utcCalendar
        ).first)

        XCTAssertEqual(summary.learningMinutes, 30)
        XCTAssertEqual(summary.practiceMinutes, 25)
        XCTAssertEqual(summary.sessionCount, 2)
        XCTAssertEqual(summary.days.reduce(0) { $0 + $1.totalMinutes }, 55)
    }

    func testCoachContextIncludesOnlySelectedProjectAndRecentTenRecords() throws {
        let selected = Project(
            name: "CS336",
            area: "AI",
            goal: "Build a language model",
            status: .active,
            currentNextStep: "Implement tokenizer"
        )
        let other = Project(
            name: "Private Other Project",
            area: "Other",
            goal: "Must not leak",
            status: .active,
            currentNextStep: "Hidden"
        )
        var selectedSessions: [LearningSession] = []
        for index in 0..<12 {
            let startedAt = now.addingTimeInterval(Double(-index * 3_600 - 1_800))
            let endedAt = now.addingTimeInterval(Double(-index * 3_600))
            selectedSessions.append(try LearningSession(
                projectId: selected.id,
                source: .quickLog,
                actionType: .course,
                startedAt: startedAt,
                endedAt: endedAt,
                durationMinutes: 30,
                note: "CS record \(index)",
                nextStepBefore: "",
                nextStepAfter: ""
            ))
        }
        let otherSession = try LearningSession(
            projectId: other.id,
            source: .quickLog,
            actionType: .course,
            startedAt: now.addingTimeInterval(-1_800),
            endedAt: now,
            durationMinutes: 30,
            note: "Secret other record",
            nextStepBefore: "",
            nextStepAfter: ""
        )

        let context = try XCTUnwrap(LearningCoachContextProjector.project(
            snapshot: JournalSnapshot(
                projects: [selected, other],
                sessions: selectedSessions + [otherSession]
            ),
            projectID: selected.id
        ))

        XCTAssertEqual(context.projectName, "CS336")
        XCTAssertEqual(context.recentRecords.count, 10)
        XCTAssertFalse(context.recentRecords.contains { $0.note.contains("Secret") })
    }

    func testPrimaryTabsIncludeTrailAndCoach() {
        XCTAssertEqual(StudioExperienceContract.vNextPrimaryTabs, [.today, .courses, .trail, .coach])
    }

    func testCoachDocumentRequiresReadableTextAndPreservesExtractedContent() throws {
        XCTAssertThrowsError(try LearningCoachAttachment(
            kind: .document,
            fileName: "archive.zip",
            mimeType: "application/zip",
            data: Data([0x01]),
            extractedText: nil
        )) { error in
            XCTAssertEqual(error as? LearningCoachAttachmentError, .unsupportedFile)
        }

        let document = try LearningCoachAttachment(
            kind: .document,
            fileName: "notes.md",
            mimeType: "text/markdown",
            data: Data("# Notes".utf8),
            extractedText: "# Notes"
        )

        XCTAssertEqual(document.extractedText, "# Notes")
        XCTAssertEqual(document.aiInput.kind, .document)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
