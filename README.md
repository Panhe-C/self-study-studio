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
- Normalized SwiftData runtime store for Projects, Sessions, Proofs, Reviews, Trail events, and onboarding state; one-time import from legacy `journal.json`
- JSON export plus attachment directory export from Library
- SwiftUI screens for onboarding, Today, Projects, Library, Quick Log, Timer, Review, Proof detail, and AI Review settings

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

## Not In v0.1

Per the PRD, these are intentionally not implemented yet:

- AI course planning
- CloudKit/iCloud sync
- Accounts
- Social features
- Rankings or streak pressure
- Course marketplace
- Complex calendar scheduling
- Complete Pomodoro system
- Full autonomous learning agent
- Search
- Desktop or web app
