# Merge compatible edits and surface real conflicts

The Web Workspace and iPhone App automatically merge independently created records and edits to different fields, while same-field and structural collisions become explicit Sync Conflicts for the learner to resolve. Consequential publication operations use a Revision Guard and fail safely on stale state; last-write-wins is rejected because it can silently discard planning and review decisions.
