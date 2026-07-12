# Personal Learning Journal

Personal Learning Journal is a SwiftUI-first app core for the v0.1 PRD in `personal-learning-journal-design.md`.

The current implementation focuses on the first product loop:

```text
Continue today -> record in 30 seconds -> attach Proof -> review the week
```

## What Is Implemented

- Two-step onboarding for 1-3 current projects with `name`, `area`, `goal`, one `Next Step`, and a required first Session before Today opens
- Project creation after onboarding, plus edit and status changes
- Today continue cards for active projects with a clear next step, latest Session, and latest Proof context
- Review prompts for active projects that have gone quiet for 7 days or when recent evidence is ready to review
- Quick Log sessions with project defaults, presets, custom duration stepping, and first-onboarding completion
- Timer sessions with pause, resume, end, discard, and a live active-duration display
- Proof creation with a required "What does this prove?" statement
- Proof entry points from Project, Session, Quick Log, Timer, and Library
- Photo Proof from camera or photo library, audio recording, file import, and links
- Proof detail screens: image preview, local audio playback, Quick Look file preview, and link opening
- Project Learning Trail events for sessions, Proofs, Next Step changes, status changes, and reviews
- Project status transitions: `active`, `low-frequency`, `paused`, `archived`
- Project detail actions for Start, Quick Log, Proof, Learning Trail, and historical Reviews
- Async Weekly Review through an `AIReviewProvider` abstraction
- OpenAI-compatible Chat Completions provider configurable in the app; endpoint/model live in preferences and API keys live in Keychain
- Rule-based review fallback that outputs Facts, Patterns, Decisions, and Next Steps when no provider is configured or available
- Editable Review results with source references under generated insights and explicit actions to apply suggested project status or Next Step
- Manual and AI-assisted course planning from a Project, with course outline, goal, expected outcome, dates, weekly budget, phases, expected Proof, and concrete study sessions
- An editable four-step plan draft flow: AI output is validated locally and stays a draft until the user explicitly activates it; revisions preserve prior plans as history
- Active-plan sessions appear in Today when due or overdue; Start and Quick Log carry planned-session context so the resulting learning record atomically completes the planned session, while Proof stays linked to the actual record
- Weekly Review includes active-plan revision, phase, completion, missed-deadline, and expected-Proof summaries with plan/phase/session source references
- AI course planning uses the existing endpoint/model/key configuration; it sends only the course input and summarized learning context, never Calendar event content, contacts, or location data
- Normalized SwiftData runtime store for Projects, Sessions, Proofs, Reviews, Trail events, and onboarding state; one-time import from legacy `journal.json`
- JSON export plus attachment directory export from Library
- SwiftUI screens for onboarding, Today, Projects, Library, Quick Log, Timer, Review, Proof detail, and AI Review settings
- Private personal iCloud sync foundation with an account-scoped journal store, encrypted-independent local attachment handling, retryable outbox, conflict review, and a visible iCloud status surface

## Current Shape

This repository provides both a Swift Package and a minimal iOS app project:

- Library target: `PersonalLearningJournal`
- Test target: `PersonalLearningJournalTests`
- iOS app project: `SelfStudyStudio.xcodeproj`
- iOS app target: `SelfStudyStudio`

The Xcode app target compiles the same SwiftUI app core and includes generated Info.plist permission strings for camera, photo library, microphone access, and document sharing.

## Verify

Run the test suite:

```bash
swift test
```

Build the package:

```bash
swift build
```

Build the iOS Simulator app target:

```bash
xcodebuild -project SelfStudyStudio.xcodeproj -target SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Current verification status:

- 2026-07-10: `swift test` completed 49 tests with 0 failures.
- 2026-07-10: `swift build` completed successfully.
- 2026-07-10: `xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build` completed successfully.
- 2026-07-10: the app installed and launched on an iPhone 16 Pro Simulator. Existing `journal.json` data appeared in Today after startup, while `journal.store` and its SQLite sidecars were created alongside the untouched legacy JSON file.
- 2026-07-12: `swift test` completed 105 tests with 0 failures, and the iOS Simulator build completed successfully after adding course planning.

## iCloud Device Acceptance

Before testing on devices, select an Apple Developer Team for `SelfStudyStudio`, create and associate the `iCloud.com.local.selfstudystudio` container, then enable iCloud/CloudKit and Push Notifications for the app identifier. Promote the development CloudKit schema before distributing a release build.

For a two-device test, sign both devices into the same Apple Account, install signed development builds, and create a learning record on each device. Verify that records made while airplane mode is enabled remain queued, upload once connectivity returns, and become visible on the other device. Attach one image, audio file, and document, then verify every downloaded attachment opens after synchronization. Finally, sign out of iCloud or switch accounts on one device and confirm the app keeps the accounts in separate local stores; exports must continue to omit account identifiers, CloudKit metadata, queued mutations, conflicts, and Calendar bindings.

## Not In v0.1

Per the PRD, these are intentionally not implemented yet:

- Social features
- Rankings or streak pressure
- Course marketplace
- Complex calendar scheduling (Calendar availability, timed placement, and EventKit write-back are the next implementation stage)
- Complete Pomodoro system
- Full autonomous learning agent
- Search
- Desktop or web app
