# Personal Learning Journal v0.1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first working Personal Learning Journal slice from the PRD: project onboarding, Today continue flow, quick log/timer session capture, Proof, Learning Trail, weekly Review, local storage, and JSON export.

**Architecture:** Create a Swift Package that contains the reusable iOS app core and SwiftUI screens. Keep domain models and journal operations independent from SwiftUI so the PRD behavior can be tested with `swift test`; SwiftUI views consume a single `JournalViewModel`.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation, SwiftUI, Observation, XCTest. No network dependencies. v0.1 uses a local JSON store abstraction in place of CloudKit and leaves AI review behind a deterministic provider protocol for testability.

## Global Constraints

- Product shape: iOS native personal tool.
- v0.1 scope: record loop plus review loop only.
- v0.1 includes: onboarding/project creation, Today continue, quick log, timer session save, Session log, Proof, Project Trail, project status, Weekly Review, AI review abstraction, local storage, JSON and attachment export.
- v0.1 excludes: AI course planning, CloudKit/iCloud sync, accounts, social, rankings, course marketplace, complex calendar, complete Pomodoro system, full autonomous agent, search, desktop, web.
- UX rules: Continue first, no gamified streaks, no pressure copy, one clear Next Step per active project, Proof asks "What does this prove?", AI review outputs Facts, Patterns, Decisions, Next Steps.

---

## File Structure

- `Package.swift`: Swift package manifest with library and test target.
- `Sources/PersonalLearningJournal/Domain.swift`: enums and Codable domain models.
- `Sources/PersonalLearningJournal/JournalStore.swift`: in-memory and JSON file persistence.
- `Sources/PersonalLearningJournal/JournalService.swift`: project/session/proof/status/trail operations.
- `Sources/PersonalLearningJournal/ReviewService.swift`: deterministic AI-review protocol and weekly review logic.
- `Sources/PersonalLearningJournal/ExportService.swift`: JSON export and attachment manifest support.
- `Sources/PersonalLearningJournal/JournalViewModel.swift`: observable state for SwiftUI screens.
- `Sources/PersonalLearningJournal/Views/*.swift`: Today, Projects, Library, Review, onboarding, quick-log, timer, and shared UI components.
- `Tests/PersonalLearningJournalTests/*.swift`: focused XCTest coverage for each behavior slice.

## Task 1: Scaffold Package and Domain Models

**Files:**
- Create: `Package.swift`
- Create: `Sources/PersonalLearningJournal/Domain.swift`
- Create: `Tests/PersonalLearningJournalTests/DomainTests.swift`

**Interfaces:**
- Produces: `Project`, `LearningSession`, `Proof`, `Review`, `TrailEvent`, `ProjectStatus`, `ActionType`, `SessionSource`, `ProofType`.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import PersonalLearningJournal

final class DomainTests: XCTestCase {
    func testActiveProjectRequiresANextStepForContinue() {
        let project = Project(name: "CS336", area: "AI", goal: "复现课程", currentNextStep: "整理 perplexity")
        XCTAssertTrue(project.canContinue)
    }

    func testActiveProjectWithoutNextStepDoesNotContinue() {
        let project = Project(name: "Guitar", area: "Music", goal: "完整弹唱 3 首歌", currentNextStep: "")
        XCTAssertFalse(project.canContinue)
    }
}
```

- [ ] **Step 2: Run red**

Run: `swift test --filter DomainTests`

Expected: failure because the package and models do not exist.

- [ ] **Step 3: Implement domain models**

Create `Package.swift` and `Domain.swift` with the enums, Codable structs, IDs, timestamps, and computed helpers used by later tasks.

- [ ] **Step 4: Run green**

Run: `swift test --filter DomainTests`

Expected: pass.

## Task 2: Store and Core Journal Operations

**Files:**
- Create: `Sources/PersonalLearningJournal/JournalStore.swift`
- Create: `Sources/PersonalLearningJournal/JournalService.swift`
- Create: `Tests/PersonalLearningJournalTests/JournalServiceTests.swift`

**Interfaces:**
- Consumes: domain models from Task 1.
- Produces: `JournalService.createProject`, `quickLog`, `saveTimerSession`, `addProof`, `updateProjectStatus`, `todayContinueProjects`, `trailEvents`.

- [ ] **Step 1: Write failing tests**

Cover onboarding project creation, Today continue ordering, quick log defaults, timer save, Proof statement requirement, status changes, and Trail event derivation.

- [ ] **Step 2: Run red**

Run: `swift test --filter JournalServiceTests`

Expected: failure because `JournalService` does not exist.

- [ ] **Step 3: Implement store and service**

Implement `JournalSnapshot`, `JournalStore`, `InMemoryJournalStore`, `JSONJournalStore`, and `JournalService`.

- [ ] **Step 4: Run green**

Run: `swift test --filter JournalServiceTests`

Expected: pass.

## Task 3: Weekly Review and Export

**Files:**
- Create: `Sources/PersonalLearningJournal/ReviewService.swift`
- Create: `Sources/PersonalLearningJournal/ExportService.swift`
- Create: `Tests/PersonalLearningJournalTests/ReviewServiceTests.swift`
- Create: `Tests/PersonalLearningJournalTests/ExportServiceTests.swift`

**Interfaces:**
- Consumes: `JournalSnapshot`, `LearningSession`, `Proof`, `Project`.
- Produces: `ReviewService.createWeeklyReview`, `AIReviewProvider`, `RuleBasedReviewProvider`, `ExportService.exportJSON`.

- [ ] **Step 1: Write failing tests**

Cover Fact/Pattern/Decision/Next Step output, source references, "no more than 3 suggestions", manual fallback when AI provider is unavailable, and JSON export shape.

- [ ] **Step 2: Run red**

Run: `swift test --filter ReviewServiceTests` and `swift test --filter ExportServiceTests`

Expected: failure because review/export services do not exist.

- [ ] **Step 3: Implement review and export services**

Implement provider protocol, deterministic rule-based provider, review persistence, and JSON export using `JSONEncoder`.

- [ ] **Step 4: Run green**

Run: `swift test --filter ReviewServiceTests && swift test --filter ExportServiceTests`

Expected: pass.

## Task 4: SwiftUI View Model and Screens

**Files:**
- Create: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Create: `Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift`
- Create: `Sources/PersonalLearningJournal/Views/RootView.swift`
- Create: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Create: `Sources/PersonalLearningJournal/Views/ProjectsView.swift`
- Create: `Sources/PersonalLearningJournal/Views/LibraryView.swift`
- Create: `Sources/PersonalLearningJournal/Views/ReviewView.swift`
- Create: `Sources/PersonalLearningJournal/Views/OnboardingView.swift`
- Create: `Sources/PersonalLearningJournal/Views/QuickLogView.swift`
- Create: `Sources/PersonalLearningJournal/Views/TimerSessionView.swift`
- Create: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`

**Interfaces:**
- Consumes: `JournalService`, `ReviewService`, `ExportService`.
- Produces: app-facing commands and SwiftUI screens for the PRD flows.

- [ ] **Step 1: Write failing view-model tests**

Cover onboarding completion, Today continue cards, quick-log save, timer save, Proof save, weekly review creation, and tab-visible data.

- [ ] **Step 2: Run red**

Run: `swift test --filter JournalViewModelTests`

Expected: failure because the view model does not exist.

- [ ] **Step 3: Implement view model and SwiftUI screens**

Implement testable view-model methods first, then SwiftUI screens that render the three-tab structure and key flows.

- [ ] **Step 4: Run green**

Run: `swift test --filter JournalViewModelTests`

Expected: pass.

## Task 5: Full Verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: all implementation tasks.
- Produces: verification evidence and usage notes.

- [ ] **Step 1: Run full test suite**

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 2: Build package**

Run: `swift build`

Expected: build succeeds.

- [ ] **Step 3: Document current run path**

Create `README.md` with the implemented v0.1 slice, verification commands, and note that this repository currently provides a Swift Package app core and SwiftUI app entry rather than a generated `.xcodeproj`.
