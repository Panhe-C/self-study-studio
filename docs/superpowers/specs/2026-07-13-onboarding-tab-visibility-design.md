# Onboarding Tab Visibility Design

## Goal

Keep the main tab bar visible after the user has created at least one project, even when the required first learning record is still pending.

## Behavior

- With no projects, `RootView` continues to show the project-creation onboarding flow.
- With at least one project, `RootView` shows Today, Projects, Calendar, and Library regardless of `hasCompletedOnboarding`.
- When `pendingFirstRecordProject` exists, Today shows a compact first-record prompt near the top. Its action opens `QuickLogView` for that project.
- Saving the first Quick Log keeps the existing domain behavior: onboarding becomes complete and the pending project ID clears.
- No persistence, sync, or domain-model changes are required.

## Testing

- View-model presentation tests cover no-project onboarding, pending-first-record tabs, and completed-onboarding tabs.
- Existing onboarding completion tests continue to verify that the first saved session clears the pending state.

