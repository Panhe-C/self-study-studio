# Onboarding Tab Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the main tab bar as soon as a project exists while preserving the required first-record prompt on Today.

**Architecture:** Add a pure `JournalViewModel.shouldShowMainTabs` presentation property and use it in `RootView`. Today reads the existing `pendingFirstRecordProject` and presents `QuickLogView`; domain completion remains unchanged.

**Tech Stack:** Swift 6, SwiftUI, XCTest

## Global Constraints

- Users with zero projects remain in project-creation onboarding.
- Users with at least one project always see the four main tabs.
- The first learning record remains required to complete onboarding.
- No persistence or sync schema changes.

---

### Task 1: Navigation Gate And Today Prompt

**Files:**
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Modify: `Sources/PersonalLearningJournal/Views/RootView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Modify: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`

- [ ] Add failing tests for `shouldShowMainTabs` with zero projects, a pending first-record project, and completed onboarding.
- [ ] Run `swift test --filter JournalViewModelTests` and verify the new API is missing.
- [ ] Implement the presentation property, switch `RootView` to it, and add the Today first-record action that opens `QuickLogView`.
- [ ] Run focused tests, `swift test`, and the iPhone 16 Pro simulator build.
- [ ] Install, launch, and verify the tab bar appears while the first-record prompt is still pending.
