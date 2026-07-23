import assert from "node:assert/strict";
import test from "node:test";

import { projectNavigationState } from "../lib/workspace-navigation.ts";

test("opens the requested Project tab with one complete navigation state", () => {
  assert.deepEqual(projectNavigationState("cs336", "reviews"), {
    section: "project",
    projectId: "cs336",
    tab: "reviews",
  });
});
