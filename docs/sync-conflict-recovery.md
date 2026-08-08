# Terminal sync conflict recovery

Guarded CloudKit writes that fail because their revision expectation is stale
are retained as terminal outbox mutations. They are excluded from automatic
pushes, but remain visible in **iCloud Sync → Terminal Sync Recovery**.

- **Retry with Current Guard** reads the latest persisted record-change tag,
  replaces the local payload and guard in one repository transaction, and
  requeues the original mutation ID. The stale guard is never reused.
- **Discard** removes the terminal outbox item while preserving the local
  entity. It is an explicit decision not to upload that mutation.

Both actions are persisted by SwiftData and survive a store restart. A follow-up
sync re-evaluates the terminal queue; once it is empty, the coordinator reports
`synced` rather than leaving the previous terminal failure visible.
