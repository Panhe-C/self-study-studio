# Task 3 Report: CloudKit, Merge, Export, And Migration Coverage

## Scope Completed

- Preserved the Task 2 `CloudRecordMapper` cases and decode validation.
- Added practice routine/session merge dispatch in `SyncMergeService`.
- Added practice routine/session snapshot conversion for Cloud account bootstrap.
- Added practice routine/session data to `JournalExport` and export JSON.
- Kept legacy export JSON decodable when the new practice collections are absent.
- Added practice routine/session conversion to the v1 repository migration.
- Added focused CloudKit round-trip, upload/download/delete, tombstone merge, bootstrap, export, legacy export decode, and migration coverage.

## RED Evidence

1. Added Task 3 integration tests, then ran:

   ```sh
   swift test --filter 'CloudRecordMapperTests|CloudSyncEndToEndTests|SyncMergeServiceTests|CloudAccountCoordinatorTests|ExportServiceTests|RepositoryMigrationTests'
   ```

   The build failed as expected in `ExportServiceTests`: `JournalExport` had no `practiceRoutines` or `practiceSessions` members.

2. During self-review, added a legacy-export compatibility test and ran:

   ```sh
   swift test --filter ExportServiceTests.testLegacyExportDecodesWithEmptyPracticeCollections
   ```

   The test failed as expected with `keyNotFound(practiceRoutines)` after removing the new keys from a v0.2-shaped export payload.

## GREEN Evidence

1. After adding the integration switches and adapting test fixtures to existing coordinator metadata and ISO-8601 date precision behavior:

   ```sh
   swift test --filter 'CloudRecordMapperTests|CloudSyncEndToEndTests|SyncMergeServiceTests|CloudAccountCoordinatorTests|ExportServiceTests|RepositoryMigrationTests'
   ```

   Result: 41 tests passed, 0 failures.

2. After adding default decoding for the two new export collections:

   ```sh
   swift test --filter ExportServiceTests.testLegacyExportDecodesWithEmptyPracticeCollections
   ```

   Result: 1 test passed, 0 failures.

3. Final full verification:

   ```sh
   swift test
   ```

   Result: 156 tests passed, 0 failures.

4. `git diff --check` completed without whitespace errors.

## Self-Review

- The only production switches added are the four Task 3 integration points: merge dispatch, account bootstrap conversion, export payload, and repository migration conversion.
- CloudKit mapping was intentionally left unchanged because Task 2 already supplies exhaustive `PracticeRoutine` and `PracticeSession` record mapping plus decode validation.
- The CloudKit end-to-end deletion test uses the existing coordinator pattern: the locally uploaded entity has sync metadata, so the simulated CloudKit record deletion resolves its stable record name through the repository.
- No Task 3 blocking concerns found.
