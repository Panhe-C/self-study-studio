import CloudKit
import XCTest
@testable import PersonalLearningJournal

final class CloudRecordMapperTests: XCTestCase {
    private let fixedID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
    private let zoneID = CKRecordZone.ID(
        zoneName: "LearningJournalZone",
        ownerName: CKCurrentUserDefaultName
    )

    func testProjectMapsToStablePrivateZoneRecord() throws {
        let project = Project(
            id: fixedID,
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1",
            createdAt: Date(timeIntervalSince1970: 10_000),
            updatedAt: Date(timeIntervalSince1970: 10_000)
        )
        let mapper = CloudRecordMapper()

        let record = try mapper.record(for: .project(project), zoneID: zoneID)

        XCTAssertEqual(record.recordID.recordName, fixedID.uuidString)
        XCTAssertEqual(record.recordID.zoneID, zoneID)
        XCTAssertEqual(record.recordType, "Project")
        XCTAssertEqual(record["name"] as? String, "CS336")
        XCTAssertEqual(try mapper.entity(from: record), .project(project))
    }

    func testProofMappingExcludesLocalPathAndUsesAssetHash() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachmentURL = root.appendingPathComponent("practice.m4a")
        try Data("audio proof".utf8).write(to: attachmentURL)
        let proof = try Proof(
            id: fixedID,
            projectId: UUID(),
            type: .audio,
            title: "Practice",
            statement: "Shows the first verse is complete",
            localPath: attachmentURL.path,
            mimeType: "audio/m4a",
            fileSize: 11,
            createdAt: Date(timeIntervalSince1970: 10_000),
            updatedAt: Date(timeIntervalSince1970: 10_000)
        )

        let record = try CloudRecordMapper().record(for: .proof(proof), zoneID: zoneID)

        XCTAssertNil(record["localPath"])
        XCTAssertNotNil(record["asset"] as? CKAsset)
        XCTAssertEqual(record["contentHash"] as? String, "e1a7eefc295fc359ba4f9990c211f625e2b200d0e2f1580a4ac66c44263a7f07")
    }

    func testDownloadedProofAssetIsCopiedBeforeTemporaryFileDisappears() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporaryAssetURL = root.appendingPathComponent("download.png")
        try Data("image".utf8).write(to: temporaryAssetURL)
        let mapper = CloudRecordMapper(
            attachmentStore: AttachmentStore(rootDirectory: root.appendingPathComponent("library"))
        )

        let destination = try mapper.importAsset(at: temporaryAssetURL, proofID: fixedID)
        try FileManager.default.removeItem(at: temporaryAssetURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("image".utf8))
    }

    func testMapperRejectsInvalidEnumValues() throws {
        let record = CKRecord(
            recordType: "Project",
            recordID: CKRecord.ID(recordName: fixedID.uuidString, zoneID: zoneID)
        )
        record["name"] = "CS336"
        record["area"] = "AI"
        record["goal"] = "Finish"
        record["status"] = "not-a-status"
        record["currentNextStep"] = "Lecture 1"
        record["lastActionType"] = "course"
        record["defaultDurationMinutes"] = 30
        record["createdAt"] = Date()
        record["updatedAt"] = Date()
        record["schemaVersion"] = 2

        XCTAssertThrowsError(try CloudRecordMapper().entity(from: record))
    }

    func testReviewRoundTripsRelationshipTextWithoutDelimiterLoss() throws {
        let projectID = UUID()
        let review = Review(
            id: fixedID,
            periodStart: Date(timeIntervalSince1970: 10_000),
            periodEnd: Date(timeIntervalSince1970: 20_000),
            facts: ["One fact"],
            patterns: ["One pattern"],
            decisions: ["Keep focus | trim scope"],
            projectRecommendations: [projectID: .lowFrequency],
            nextSteps: [projectID: "Read A | then B"],
            aiSourceSummary: ["Summary"],
            sourceReferences: ["Keep focus | trim scope": ["session | 1"]],
            createdAt: Date(timeIntervalSince1970: 30_000),
            updatedAt: Date(timeIntervalSince1970: 30_000)
        )
        let mapper = CloudRecordMapper()

        let record = try mapper.record(for: .review(review), zoneID: zoneID)

        XCTAssertEqual(try mapper.entity(from: record), .review(review))
    }

    func testPlanningEntitiesRoundTripInPrivateZone() throws {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let projectID = UUID()
        let plan = try CoursePlan(
            id: fixedID,
            projectId: projectID,
            revision: 1,
            status: .active,
            courseURL: URL(string: "https://cs336.stanford.edu"),
            courseTitle: "CS336",
            courseOutline: "Language models",
            goal: "Build a model",
            expectedOutcome: "Notebook",
            startsOn: timestamp,
            deadline: timestamp.addingTimeInterval(7 * 24 * 60 * 60),
            weeklyBudgetMinutes: 240,
            summary: "Build foundations.",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let phase = try PlanPhase(
            planId: plan.id,
            title: "Tokenizer",
            objective: "Understand tokenization",
            expectedProof: "Tokenizer notebook",
            ordinal: 0,
            targetStart: timestamp,
            targetEnd: timestamp.addingTimeInterval(24 * 60 * 60),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let session = try PlannedSession(
            planId: plan.id,
            phaseId: phase.id,
            projectId: projectID,
            title: "Implement tokenizer",
            actionType: .course,
            expectedProof: "Tokenizer notebook",
            durationMinutes: 45,
            deadline: timestamp.addingTimeInterval(24 * 60 * 60),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let mapper = CloudRecordMapper()

        for entity in [JournalEntity.coursePlan(plan), .planPhase(phase), .plannedSession(session)] {
            let record = try mapper.record(for: entity, zoneID: zoneID)
            XCTAssertEqual(try mapper.entity(from: record), entity)
        }
    }

    func testAvailabilityAndPreferencesRoundTripWithoutCalendarBindings() throws {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let availability = try AvailabilityRule(
            id: fixedID,
            weekday: 2,
            startMinute: 18 * 60,
            endMinute: 21 * 60,
            timeZoneIdentifier: "Asia/Shanghai",
            minimumSessionMinutes: 30,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let preferences = try SchedulingPreferences(
            preferredSessionMinutes: 45,
            maximumDailyMinutes: 120,
            minimumGapMinutes: 15,
            updatedAt: timestamp
        )
        let mapper = CloudRecordMapper()

        let availabilityRecord = try mapper.record(for: .availabilityRule(availability), zoneID: zoneID)
        let preferencesRecord = try mapper.record(for: .schedulingPreferences(preferences), zoneID: zoneID)

        XCTAssertEqual(availabilityRecord.recordType, "AvailabilityRule")
        XCTAssertEqual(preferencesRecord.recordType, "SchedulingPreferences")
        XCTAssertEqual(try mapper.entity(from: availabilityRecord), .availabilityRule(availability))
        XCTAssertEqual(try mapper.entity(from: preferencesRecord), .schedulingPreferences(preferences))
        XCTAssertNil(availabilityRecord["eventIdentifier"])
        XCTAssertNil(preferencesRecord["calendarIdentifier"])
    }

    func testPracticeRoutineRejectsInvalidTargetMinutes() throws {
        let record = try practiceRoutineRecord()
        record["targetMinutes"] = 0

        XCTAssertThrowsError(try CloudRecordMapper().entity(from: record))
    }

    func testPracticeRoutineRejectsEmptyOrOutOfRangeWeekdays() throws {
        let emptyWeekdaysRecord = try practiceRoutineRecord()
        emptyWeekdaysRecord["weekdays"] = [] as NSArray

        let invalidWeekdayRecord = try practiceRoutineRecord()
        invalidWeekdayRecord["weekdays"] = [8] as NSArray

        XCTAssertThrowsError(try CloudRecordMapper().entity(from: emptyWeekdaysRecord))
        XCTAssertThrowsError(try CloudRecordMapper().entity(from: invalidWeekdayRecord))
    }

    func testPracticeRoutineRejectsBlankName() throws {
        let record = try practiceRoutineRecord()
        record["name"] = "   "

        XCTAssertThrowsError(try CloudRecordMapper().entity(from: record))
    }

    func testPracticeRoutineRejectsInvalidReminderTime() throws {
        let record = try practiceRoutineRecord()
        record["reminderHour"] = 24
        record["reminderMinute"] = 0

        XCTAssertThrowsError(try CloudRecordMapper().entity(from: record))
    }

    func testPracticeSessionRejectsImpossibleTiming() throws {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let session = PracticeSession(
            id: fixedID,
            routineId: UUID(),
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            activeDurationSeconds: 60,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let record = try CloudRecordMapper().record(for: .practiceSession(session), zoneID: zoneID)
        record["activeDurationSeconds"] = 62

        XCTAssertThrowsError(try CloudRecordMapper().entity(from: record))
    }

    func testMapperRejectsInvalidDurationAndRecordIdentifier() throws {
        let invalidIDRecord = CKRecord(
            recordType: "Project",
            recordID: CKRecord.ID(recordName: "not-a-uuid", zoneID: zoneID)
        )
        XCTAssertThrowsError(try CloudRecordMapper().entity(from: invalidIDRecord))

        let record = CKRecord(
            recordType: "LearningSession",
            recordID: CKRecord.ID(recordName: fixedID.uuidString, zoneID: zoneID)
        )
        record["projectId"] = UUID().uuidString
        record["source"] = "quickLog"
        record["actionType"] = "course"
        record["startedAt"] = Date()
        record["endedAt"] = Date()
        record["durationMinutes"] = 0
        record["note"] = "A note"
        record["nextStepBefore"] = "Before"
        record["nextStepAfter"] = "After"
        record["createdAt"] = Date()
        record["updatedAt"] = Date()
        record["schemaVersion"] = 2

        XCTAssertThrowsError(try CloudRecordMapper().entity(from: record))
    }

    func testMapperRejectsMalformedOptionalRelationshipsAndReferences() throws {
        let proofRecord = CKRecord(
            recordType: "Proof",
            recordID: CKRecord.ID(recordName: fixedID.uuidString, zoneID: zoneID)
        )
        proofRecord["projectId"] = UUID().uuidString
        proofRecord["sessionId"] = "not-a-uuid"
        proofRecord["type"] = "link"
        proofRecord["title"] = "Notes"
        proofRecord["statement"] = "Shows the notes"
        proofRecord["createdAt"] = Date()
        proofRecord["updatedAt"] = Date()
        proofRecord["schemaVersion"] = 2
        XCTAssertThrowsError(try CloudRecordMapper().entity(from: proofRecord))

        let reviewRecord = CKRecord(
            recordType: "Review",
            recordID: CKRecord.ID(recordName: fixedID.uuidString, zoneID: zoneID)
        )
        reviewRecord["periodStart"] = Date()
        reviewRecord["periodEnd"] = Date()
        reviewRecord["sourceReferences"] = ["not-base64"] as NSArray
        reviewRecord["createdAt"] = Date()
        reviewRecord["updatedAt"] = Date()
        reviewRecord["schemaVersion"] = 2
        XCTAssertThrowsError(try CloudRecordMapper().entity(from: reviewRecord))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func practiceRoutineRecord() throws -> CKRecord {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let routine = PracticeRoutine(
            id: fixedID,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return try CloudRecordMapper().record(for: .practiceRoutine(routine), zoneID: zoneID)
    }
}
