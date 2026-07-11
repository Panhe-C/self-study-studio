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
}
