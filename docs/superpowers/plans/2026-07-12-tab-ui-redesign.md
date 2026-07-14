# Tab UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Today, Projects, Calendar, and Library root tabs to match the approved premium iOS demos without removing any existing self-study behavior.

**Architecture:** Add one small presentation layer for deterministic display calculations and one shared SwiftUI theme/components file. Each root tab owns its page-specific composition and continues to call the existing view models, sheets, navigation destinations, and calendar services.

**Tech Stack:** Swift 6, SwiftUI, Foundation, XCTest, Swift Package Manager, Xcode iOS Simulator.

## Global Constraints

- Preserve all existing course planning, timer, quick log, proof, review, sync, calendar draft, and reconciliation workflows.
- Use only real repository/view-model data; do not ship demo records or remote image dependencies.
- Use system typography and SF Symbols with cool off-white, charcoal, cobalt, sage, and coral tokens; no gradients, glass effects, purple theme, or nested cards.
- Keep Dynamic Type, VoiceOver, safe areas, and iPhone 16 Pro layout stability.
- Do not add People or social functionality, persistence migrations, or redesign detail screens and forms.

---

### Task 1: Presentation Models And Shared Visual System

**Files:**
- Create: `Sources/PersonalLearningJournal/Views/StudioPresentation.swift`
- Create: `Sources/PersonalLearningJournal/Views/StudioTheme.swift`
- Create: `Tests/PersonalLearningJournalTests/StudioPresentationTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `StudioWeekDay`, `StudioProjectProgress`, `StudioLibraryFilter`, `StudioTheme`, `StudioSectionHeader`, and `StudioNoticeRow`.
- Consumes: `Project`, `LearningSession`, `Proof`, `CoursePlan`, `PlanPhase`, and `PlannedSession`.

- [ ] **Step 1: Write failing presentation tests**

```swift
func testWeekRhythmCountsSessionMinutesByCalendarDay() {
    let days = StudioPresentation.weekRhythm(sessions: [monday30, monday45], weekContaining: monday30.endedAt, calendar: calendar)
    XCTAssertEqual(days.map(\.minutes), [75, 0, 0, 0, 0, 0, 0])
}

func testProjectProgressUsesCompletedPlannedSessions() {
    XCTAssertEqual(StudioPresentation.progress(completed: 2, total: 5), 0.4)
}

func testLibraryFilterMatchesProjectAndProofTextCaseInsensitively() {
    XCTAssertTrue(StudioPresentation.proofMatches(query: "cs336", proof: proof, projectName: "CS336"))
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --filter StudioPresentationTests`

Expected: compilation fails because `StudioPresentation` does not exist.

- [ ] **Step 3: Implement deterministic presentation helpers**

```swift
public enum StudioPresentation {
    public static func progress(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    public static func proofMatches(query: String, proof: Proof, projectName: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return [proof.title, proof.statement, proof.type.rawValue, projectName]
            .contains { $0.lowercased().contains(query) }
    }
}
```

Add the seven-day calendar implementation and value types required by the tests. Add `StudioTheme` semantic colors and reusable unframed section/notice views. Register both new source files in the Xcode project.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter StudioPresentationTests`

Expected: all `StudioPresentationTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PersonalLearningJournal/Views/StudioPresentation.swift Sources/PersonalLearningJournal/Views/StudioTheme.swift Tests/PersonalLearningJournalTests/StudioPresentationTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: add studio presentation system"
```

### Task 2: Today Dashboard

**Files:**
- Modify: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Test: `Tests/PersonalLearningJournalTests/StudioPresentationTests.swift`

**Interfaces:**
- Consumes: `StudioPresentation.weekRhythm`, `StudioTheme`, `StudioSectionHeader`, `StudioNoticeRow`, `JournalViewModel`, and `CalendarViewModel`.
- Preserves: all existing sheets, review creation, sync link, planned-session actions, retry, reconciliation, and schedule conflict display.

- [ ] **Step 1: Add a failing focus-selection test**

```swift
func testFocusPrefersEarliestPlannedSessionThenActiveProject() {
    let selected = StudioPresentation.focusProject(projects: [project], planned: [later, earlier])
    XCTAssertEqual(selected?.projectID, earlier.project.id)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --filter StudioPresentationTests/testFocusPrefersEarliestPlannedSessionThenActiveProject`

Expected: fails because `focusProject` is missing.

- [ ] **Step 3: Implement focus selection and rebuild Today layout**

Replace the root `List` with a `ScrollView` and `LazyVStack`. Compose date, week rhythm, current focus, chronological timeline, quick log, and compact operational notices. Route Start/Quick Log to the same state properties and sheets already used by the view.

```swift
ScrollView {
    LazyVStack(alignment: .leading, spacing: StudioTheme.sectionSpacing) {
        StudioWeekRhythmView(days: rhythm)
        if let focus { StudioCurrentFocusView(focus: focus, onStart: start, onQuickLog: quickLog) }
        StudioTodayTimeline(contexts: todaysPlan, onStart: startPlan, onQuickLog: quickLogPlan)
        operationalNotices
        reviewSection
    }
    .padding(.horizontal, StudioTheme.pageInset)
}
.background(StudioTheme.pageBackground)
```

- [ ] **Step 4: Verify Today tests and package build**

Run: `swift test --filter StudioPresentationTests && swift build`

Expected: tests and build pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PersonalLearningJournal/Views/TodayView.swift Tests/PersonalLearningJournalTests/StudioPresentationTests.swift
git commit -m "feat: redesign today dashboard"
```

### Task 3: Projects Progress View

**Files:**
- Modify: `Sources/PersonalLearningJournal/Views/ProjectsView.swift`
- Test: `Tests/PersonalLearningJournalTests/StudioPresentationTests.swift`

**Interfaces:**
- Consumes: `StudioProjectProgress`, theme components, `JournalViewModel.activeCoursePlan(for:)`, `plannedSessions(for:)`, sessions, and proofs.
- Preserves: project creation, project detail navigation, status changes, study plans, proof, timer, and quick log flows.

- [ ] **Step 1: Add a failing status-filter test**

```swift
func testProjectFilterReturnsOnlySelectedStatus() {
    XCTAssertEqual(StudioPresentation.projects([active, paused], status: .active).map(\.id), [active.id])
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --filter StudioPresentationTests/testProjectFilterReturnsOnlySelectedStatus`

Expected: fails because the filter helper is missing.

- [ ] **Step 3: Implement filter and redesign Projects root**

Add an Active/Paused segmented control. Render the first active planned project as a larger progress section with phase labels and next step, and remaining projects as compact rows. Calculate planned progress only from actual planned-session status and show an activity indicator when no plan exists.

- [ ] **Step 4: Verify Projects tests and build**

Run: `swift test --filter StudioPresentationTests && swift build`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PersonalLearningJournal/Views/ProjectsView.swift Tests/PersonalLearningJournalTests/StudioPresentationTests.swift
git commit -m "feat: redesign project progress view"
```

### Task 4: Calendar Workspace

**Files:**
- Modify: `Sources/PersonalLearningJournal/Views/StudyCalendarView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/DayCalendarView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/WeekCalendarView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/MonthCalendarView.swift`

**Interfaces:**
- Consumes: `CalendarViewModel.visibleRange`, `items`, `unscheduledItems`, `scheduleDraft`, `reconciliationItems`, and `StudioTheme`.
- Preserves: date navigation, mode switching, schedule generation, draft sheet, settings, reconciliation, drag, resize, and privacy behavior.

- [ ] **Step 1: Run existing calendar tests as baseline**

Run: `swift test --filter CalendarViewModelTests && swift test --filter CalendarLayoutTests`

Expected: all pass before layout edits.

- [ ] **Step 2: Redesign the calendar header**

Use a fixed mode picker, readable range title, previous/next icon buttons, and a coral notice band when `unscheduledItems`, draft conflicts, or reconciliation items exist. Keep generate/settings as icon actions with accessibility labels.

- [ ] **Step 3: Restyle calendar modes**

Use cobalt planned blocks, sage completed blocks, coral conflict outlines, neutral busy blocks, stable minimum event heights, and consistent time-grid lines. Do not alter drag or resize calculations.

- [ ] **Step 4: Verify calendar behavior and build**

Run: `swift test --filter Calendar && swift build`

Expected: all calendar tests and build pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PersonalLearningJournal/Views/StudyCalendarView.swift Sources/PersonalLearningJournal/Views/DayCalendarView.swift Sources/PersonalLearningJournal/Views/WeekCalendarView.swift Sources/PersonalLearningJournal/Views/MonthCalendarView.swift
git commit -m "feat: redesign study calendar workspace"
```

### Task 5: Visual Library

**Files:**
- Modify: `Sources/PersonalLearningJournal/Views/LibraryView.swift`
- Modify: `Sources/PersonalLearningJournal/ProofPreview.swift`
- Test: `Tests/PersonalLearningJournalTests/StudioPresentationTests.swift`

**Interfaces:**
- Consumes: `StudioPresentation.proofMatches`, `ProofPreviewDescriptor`, proofs, reviews, project names, and export service.
- Preserves: add-proof project picker, proof detail navigation, grouping, export, and alert behavior.

- [ ] **Step 1: Extend failing library filter tests**

```swift
func testLibraryFilterRejectsUnrelatedText() {
    XCTAssertFalse(StudioPresentation.proofMatches(query: "guitar", proof: proof, projectName: "CS336"))
}
```

- [ ] **Step 2: Verify RED against an intentionally incomplete matcher case**

Run: `swift test --filter StudioPresentationTests/testLibraryFilterRejectsUnrelatedText`

Expected: fails until the matcher checks all and only intended fields.

- [ ] **Step 3: Rebuild Library root**

Add search and Evidence/Reviews/Exports mode. Evidence uses a two-column lazy grid with attachment previews when supported and type-based SF Symbol surfaces otherwise. Reviews shows the newest review first. Exports provides the existing export command and completion notice without adding persistence.

- [ ] **Step 4: Verify Library tests and build**

Run: `swift test --filter StudioPresentationTests && swift test --filter ProofPreviewTests && swift build`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PersonalLearningJournal/Views/LibraryView.swift Sources/PersonalLearningJournal/ProofPreview.swift Tests/PersonalLearningJournalTests/StudioPresentationTests.swift
git commit -m "feat: redesign evidence library"
```

### Task 6: Root Navigation Polish And End-To-End Verification

**Files:**
- Modify: `Sources/PersonalLearningJournal/Views/RootView.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: redesigned root views and their existing view models.
- Produces: a unified tab tint/background and documented screenshot verification.

- [ ] **Step 1: Apply root tab styling**

Set the shared cobalt tint, toolbar background visibility, and stable tab labels. Keep exactly Today, Projects, Calendar, and Library.

- [ ] **Step 2: Run full automated verification**

Run: `swift test && swift build && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO build`

Expected: 133 or more tests pass, Swift build succeeds, and Xcode reports `BUILD SUCCEEDED`.

- [ ] **Step 3: Install and visually inspect all tabs**

Install with `xcrun simctl install`, launch `com.local.selfstudystudio`, and capture screenshots for Today, Projects, Calendar, and Library. Verify nonblank content, no overlaps, readable labels, and correct selected-tab state at the iPhone 16 Pro viewport.

- [ ] **Step 4: Update README verification note**

Record the four-tab redesign and simulator verification. State that physical-device layout and CloudKit/EventKit entitlement verification remain separate.

- [ ] **Step 5: Commit**

```bash
git add Sources/PersonalLearningJournal/Views/RootView.swift README.md
git commit -m "feat: complete studio tab redesign"
```
