# Self Study Studio Tab UI Redesign

## Goal

Bring the four root tabs in line with the approved high-fidelity demos while preserving the existing self-study workflows and real data model. The redesign covers Today, Projects, Calendar, and Library. It does not replace detail screens, forms, planning logic, sync, or persistence.

## Visual System

- Use a quiet iOS-native palette: cool off-white page background, white surfaces, charcoal text, cobalt actions, sage completion, and coral warnings.
- Use system typography and SF Symbols. Large titles remain native and readable.
- Prefer full-width sections, dividers, and restrained 8-point surfaces. Avoid nested cards, gradients, glass effects, and decorative shapes.
- Introduce shared theme tokens and reusable section, status, and action components so all tabs stay consistent.
- Support Dynamic Type, VoiceOver labels, safe areas, and light/dark system contrast where practical.

## Today

- Lead with the date and a compact seven-day learning rhythm derived from sessions in the current week.
- Promote the first planned session or active project's next step into a current-focus section with Start and Quick Log actions.
- Render today's planned sessions as a chronological timeline and retain overdue, unscheduled, conflict, reconciliation, retry, review, AI settings, and sync entry points as compact operational notices or secondary sections.
- Empty state points users toward creating an active project or next step.

## Projects

- Add an Active/Paused segmented filter and keep project creation as an icon action.
- Use a prominent active-plan card showing plan progress, current phase, next step, and recent evidence when those values exist.
- Render remaining projects as compact progress rows based on completed planned sessions, sessions, and evidence. Never invent progress.
- Preserve navigation to project detail and all existing project actions.

## Calendar

- Keep Day/Week/Month modes, navigation, schedule generation, settings, and reconciliation.
- Restyle the header to match the demo, with a clear date range and compact conflict/draft notice.
- Improve day/week/month surfaces using shared schedule colors, stable geometry, readable event labels, and neutral privacy blocks for external busy time.
- Draft generation and calendar writes retain the existing preview-and-confirm workflow.

## Library

- Add search and a mode control for Evidence, Reviews, and Exports.
- Present evidence as a responsive two-column visual archive when attachments support previews, with type-based visual placeholders otherwise.
- Show the latest weekly review as a pinned summary row and preserve proof detail, add-proof, grouping/filtering, and export actions.
- Search operates on proof title, statement, type, and project name.

## Architecture

- Add a small `StudioTheme`/shared-components file under Views.
- Keep data derivation close to each root view as private computed properties or focused presentation models. Domain and repository interfaces remain unchanged unless a view needs an already-available query exposed cleanly.
- Keep each tab independently buildable. Shared code is limited to stable visual primitives, not page-specific layout abstractions.

## Testing And Acceptance

- Add focused tests for new presentation calculations where they contain logic, such as weekly rhythm, project progress, and library filtering.
- Run all Swift package tests and an iOS simulator build.
- Verify all four tabs at an iPhone 16 Pro viewport: content is nonblank, labels do not overlap, tab navigation remains available, and existing primary actions still open their flows.
- Simulator screenshots are the visual acceptance evidence. Physical-device layout and CloudKit/EventKit entitlements remain a separate verification step.

## Non-Goals

- No People or social functionality.
- No fabricated demo records, remote image service, new analytics, or new persistence schema.
- No full redesign of onboarding, detail screens, sheets, or settings in this pass.
