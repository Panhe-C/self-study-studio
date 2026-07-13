# Practice Timer Design

## Goal

Add an iHour-inspired practice timer to Today for recurring skill practice such as thirty minutes of guitar. Practice is independent from course projects, starts in one tap, accumulates real time, and may optionally link a completed practice session to an existing learning project.

## Product Decisions

- A practice routine is independent from a learning project.
- A routine has a target duration and selected weekdays.
- Today shows only routines scheduled for the current weekday.
- Timing counts upward. Reaching the target provides feedback but never stops the timer.
- Saving requires only elapsed time. Notes and project association are optional.
- Accumulated time matters more than streak pressure. The UI may show completion frequency but does not punish missed days.

## Domain Model

### PracticeRoutine

- Stable UUID, name, symbol name, semantic color name.
- Target duration in minutes, constrained to 1...1,440.
- Weekday set using Calendar weekday values 1...7.
- Optional reminder time reserved for a later notification settings pass; no reminder UI in this version.
- Active/archived state, created/updated/deleted timestamps, schema version.

### PracticeSession

- Stable UUID and required routine ID.
- Optional linked project ID.
- Started and ended timestamps plus active duration seconds.
- Optional note.
- Created/updated/deleted timestamps and schema version.

Practice sessions remain separate from `LearningSession`. When linked to a project they appear as related practice evidence in project history and review inputs, but they do not complete planned course sessions or alter course-plan progress.

## Today Experience

Add a `Practice` section below Current Focus and before operational notices.

Each scheduled routine card shows:

- Symbol, routine name, and `today / target` time.
- A compact progress ring that can exceed the target textually while the ring caps at 100%.
- One primary Start/Resume button.
- Weekly completion count, weekly accumulated time, and all-time accumulated time.

If no routine is scheduled today, show a compact `Add Practice` action rather than an empty dashboard panel. A toolbar or section action opens practice management.

## Timer Experience

The timer opens as a focused sheet with:

- Routine name, large `HH:MM:SS` elapsed time, and target progress.
- Pause/resume, finish, and discard commands using familiar symbols.
- Haptic feedback once when active elapsed time crosses the target.
- The timer derives elapsed time from persisted start/resume timestamps rather than incrementing an in-memory counter. It remains accurate across backgrounding and foregrounding.
- One active practice timer at a time. Returning to Today shows and resumes the active timer entry point.

Finish opens a lightweight confirmation sheet. Save is immediately available; note and linked project are optional. Discard requires confirmation when elapsed time is nonzero.

## Practice Management

Provide a management sheet from Today:

- List active and archived routines.
- Create/edit name, SF Symbol choice, target minutes, and weekday toggles.
- Archive instead of destructive deletion when history exists.
- Prevent duplicate blank names and invalid duration/weekday selections.

## Statistics

For each routine calculate from real sessions:

- Today's active seconds.
- This week's completed-practice count, where completion means one day's accumulated time reached the routine target.
- This week's total active duration.
- All-time active duration.

Multiple sessions on the same day combine toward the daily target. Statistics use the user's current Calendar and time zone.

## Persistence And Sync

- Add both entities to `JournalSnapshot`, `JournalEntity`, repository transactions, SwiftData storage, export, merge behavior, and CloudKit record mapping.
- Legacy snapshots decode with empty practice collections.
- Soft deletion and outbox behavior match existing entities.
- Active timer runtime state is local device state and is not synced; completed sessions are synced.
- Cloud records contain routine/session data but never derived statistics.

## Error Handling

- Repository save failures keep the finish sheet open and show a retryable error.
- If the linked project was deleted, save the practice session without the link and explain the fallback.
- Interrupted active timers recover from local runtime state. Corrupt or impossible timestamps are discarded safely and never create a session.
- Target feedback is best effort and does not block timing or saving.

## Accessibility And Visual Design

- Reuse `StudioTheme`, system typography, and SF Symbols.
- Large timer digits use monospaced system numbers and scale for Dynamic Type.
- Controls have explicit VoiceOver labels and do not rely on color alone.
- Practice cards use stable dimensions and an 8-point maximum corner radius.
- No gradients, glass effects, achievement gamification, social sharing, custom backgrounds, or ambient audio in this version.

## Testing And Acceptance

- Domain validation and legacy decoding tests.
- Repository, SwiftData restart, export, CloudKit round-trip, merge, and deletion tests.
- Statistics tests for multiple same-day sessions, week boundaries, and time zones.
- Timer state tests for pause/resume, background elapsed time, one-time target crossing, finish, discard, and corrupt recovery.
- Today presentation tests for weekday filtering and active timer resume state.
- Full Swift tests and iPhone 16 Pro simulator build.
- Simulator verification covers routine creation, start, pause, resume, target feedback path, optional note/project linking, save, and Today statistics refresh.

## Non-Goals

- Social sharing, leaderboards, streak penalties, achievements, custom timer themes, environment sounds, focus-mode device blocking, Apple Watch, widgets, or reminder scheduling.
- Converting existing learning sessions into practice sessions.
- Automatically changing learning-project next steps or course-plan completion from practice time.
