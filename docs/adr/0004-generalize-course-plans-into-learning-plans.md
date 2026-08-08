# Generalize Course Plans into Learning Plans

The canonical planning concept is a Project-owned Learning Plan composed of Plan Phases, Planned Sessions, and expected Proof; course URL and course outline are optional inputs rather than prerequisites. We will migrate the existing CoursePlan model instead of creating a parallel non-course planner, because maintaining separate course and general planning flows would duplicate activation, scheduling, completion, evidence, and review rules.

## B2 compatibility decision

The `CoursePlan` Swift API alias, `coursePlan` JournalEntity kind, and `CoursePlan` CloudKit record type remain readable and writable indefinitely. New domain and user-facing language is `LearningPlan`; explicit revision identity is carried by `planSeriesID`, `revisionID`, `baseRevisionID`, and `supersedesID`. No remote record-type migration is required.
