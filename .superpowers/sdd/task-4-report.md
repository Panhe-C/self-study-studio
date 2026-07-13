# Task 4 Report: Practice Service And Calendar-Aware Statistics

## Scope Completed

- Added `PracticeService` APIs to create, update, archive, and conditionally delete routines.
- Validated routines and sessions before persistence, with duplicate active routine names rejected after trimming and case folding.
- Required every saved practice session to reference an existing non-deleted routine.
- Preserved a live linked project ID and dropped a missing/deleted project link to `nil`, reporting that fallback through `PracticeSessionSaveResult`.
- Added pure, calendar-injected practice statistics for today, the current week, and all time.
- Aggregated same-day sessions before applying daily completion targets and ignored deleted or other-routine sessions.

## RED Evidence

1. Added the service and statistics tests, then ran:

   ```sh
   swift test --filter 'PracticeServiceTests|PracticeStatisticsTests'
   ```

   The build failed as expected because `PracticeService` and `PracticeStatistics` were not yet defined. The errors began with `cannot find 'PracticeService' in scope` and `cannot find 'PracticeStatistics' in scope`.

## GREEN Evidence

1. After implementing the practice service and pure statistics calculator:

   ```sh
   swift test --filter 'PracticeServiceTests|PracticeStatisticsTests'
   ```

   Result: 10 tests passed, 0 failures.

2. Final full verification:

   ```sh
   swift test
   ```

   Result: 166 tests passed, 0 failures.

3. `git diff --check` completed without whitespace errors.

## Self-Review

- `saveSession` reads the current repository snapshot and rejects a missing or soft-deleted routine before constructing or committing a session.
- Name comparison trims and folds case, while archived and deleted routines are excluded from the active-name uniqueness set.
- `deleteRoutineIfUnused` rejects any visible, non-deleted session that still references the routine, then uses the repository deletion transaction to create the normal soft-delete tombstone.
- `PracticeStatistics.calculate` has no repository or clock dependency and derives day/week boundaries exclusively from its injected `Calendar` and `now` arguments.
- No Task 4 blocking concerns found. Existing unrelated deprecation warnings for `ReviewHTTPTransport` remain during test compilation.
