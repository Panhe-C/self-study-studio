#!/usr/bin/env node

/**
 * D1 cross-surface acceptance and release gate.
 *
 * This runner deliberately separates deterministic package evidence from gates
 * that require Apple infrastructure, a signed device, a browser session, or a
 * human confirmation. It never prints inherited credentials or writes them to
 * the report.
 */

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const webRoot = join(repoRoot, "WebWorkspace");
const swiftModuleCachePath = "/tmp/self-study-studio-d1-module-cache";
mkdirSync(swiftModuleCachePath, { recursive: true });
const swiftChildEnv = {
  CLANG_MODULE_CACHE_PATH: swiftModuleCachePath,
  SWIFTPM_MODULECACHE_OVERRIDE: swiftModuleCachePath,
};
const args = process.argv.slice(2);
const jsonOutput = args.includes("--json");
const allowBlocked = args.includes("--allow-blocked");
const reportIndex = args.indexOf("--report");
const reportPath = reportIndex >= 0 && args[reportIndex + 1]
  ? resolve(process.cwd(), args[reportIndex + 1])
  : undefined;

function sanitize(value) {
  let output = String(value ?? "");
  const secretNames = [
    "NEXT_PUBLIC_CLOUDKIT_API_TOKEN",
    "CLOUDKIT_API_TOKEN",
    "OPENAI_API_KEY",
    "API_KEY",
  ];
  for (const name of secretNames) {
    const secret = process.env[name];
    if (secret) output = output.split(secret).join("[REDACTED]");
  }
  return output;
}

function tail(value, lineCount = 14) {
  const lines = sanitize(value)
    .split(/\r?\n/)
    .filter(Boolean);
  const highlighted = lines
    .filter((line) => /\b(?:error|warning):|BUILD (?:FAILED|SUCCEEDED)|failing build commands/i.test(line))
    .slice(-8);
  const recent = lines.slice(-lineCount);
  return [...new Set([...highlighted, ...recent])]
    .slice(-(lineCount + highlighted.length))
    .join("\n");
}

function elapsed(startedAt) {
  return Math.round((performance.now() - startedAt) * 10) / 10;
}

function gitCommit() {
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: repoRoot,
      encoding: "utf8",
    }).trim();
  } catch {
    return "unknown";
  }
}

function commandCheck(id, command, commandArgs, options = {}) {
  const startedAt = performance.now();
  const result = spawnSync(command, commandArgs, {
    cwd: options.cwd ?? repoRoot,
    encoding: "utf8",
    env: options.env ? { ...process.env, ...options.env } : process.env,
    maxBuffer: 32 * 1024 * 1024,
  });
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  const exitCode = typeof result.status === "number" ? result.status : null;
  const blockedEnvironment = options.blockedEnvironment?.(output, exitCode) === true;
  const knownBaseline = options.knownBaseline?.(output, exitCode) === true;
  const status = exitCode === 0
    ? "PASS"
    : blockedEnvironment
      ? "BLOCKED_ENVIRONMENT"
    : knownBaseline
      ? "PASS_KNOWN_BASELINE"
      : "FAIL";
  return {
    id,
    kind: "command",
    command: [command, ...commandArgs].join(" "),
    cwd: options.cwd ? options.cwd.replace(`${repoRoot}/`, "") : ".",
    status,
    exitCode,
    durationMs: elapsed(startedAt),
    outputTail: tail(output),
    ...(result.error ? { error: sanitize(result.error.message) } : {}),
  };
}

function sourceCheck(id, requirements) {
  const startedAt = performance.now();
  const missing = [];
  for (const requirement of requirements) {
    const sourcePath = join(repoRoot, requirement.file);
    const source = existsSync(sourcePath) ? readFileSync(sourcePath, "utf8") : "";
    if (!source || !requirement.patterns.every((pattern) => source.includes(pattern))) {
      missing.push({
        file: requirement.file,
        patterns: requirement.patterns,
      });
    }
  }
  return {
    id,
    kind: "source-manifest",
    status: missing.length === 0 ? "PASS" : "FAIL",
    durationMs: elapsed(startedAt),
    missing,
  };
}

function swiftSourcePaths(rootDir) {
  const paths = [];
  const pending = [rootDir];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const entryPath = join(directory, entry.name);
      if (entry.isDirectory()) {
        pending.push(entryPath);
      } else if (entry.isFile() && entry.name.endsWith(".swift")) {
        paths.push(entryPath.replace(`${repoRoot}/`, ""));
      }
    }
  }
  return paths.sort();
}

function swiftAppTargetSourceParityCheck(id) {
  const startedAt = performance.now();
  const projectPath = join(repoRoot, "SelfStudyStudio.xcodeproj/project.pbxproj");
  const project = existsSync(projectPath) ? readFileSync(projectPath, "utf8") : "";
  const buildFileSection = project.split("/* Begin PBXBuildFile section */")[1]?.split("/* End PBXBuildFile section */")[0] ?? "";
  const sourceRefIDs = new Set(
    [...buildFileSection.matchAll(/^\s*[A-Z0-9]+ .*? in Sources \*\/ = \{isa = PBXBuildFile; fileRef = ([A-Z0-9]+)/gm)]
      .map((match) => match[1]),
  );
  const fileRefs = new Map(
    [...project.matchAll(/^\s*([A-Z0-9]+) \/\* .*? \*\/ = \{isa = PBXFileReference;.*?path = (Sources\/PersonalLearningJournal\/[^;]+\.swift);/gm)]
      .map((match) => [match[1], match[2]]),
  );
  const appTargetSources = [...sourceRefIDs]
    .map((idValue) => fileRefs.get(idValue))
    .filter(Boolean)
    .sort();
  const packageSources = swiftSourcePaths(join(repoRoot, "Sources/PersonalLearningJournal"));
  const missingInApp = packageSources.filter((sourcePath) => !appTargetSources.includes(sourcePath));
  const extraInApp = appTargetSources.filter((sourcePath) => !packageSources.includes(sourcePath));
  const testSourcesInApp = appTargetSources.filter((sourcePath) => /(^|\/)Tests\//.test(sourcePath));
  return {
    id,
    kind: "source-manifest",
    status: project && missingInApp.length === 0 && extraInApp.length === 0 && testSourcesInApp.length === 0 ? "PASS" : "FAIL",
    durationMs: elapsed(startedAt),
    packageSourceCount: packageSources.length,
    appTargetSourceCount: appTargetSources.length,
    missingInApp,
    extraInApp,
    testSourcesInApp,
  };
}

function parseSwiftCounts(output) {
  const matches = [...output.matchAll(/Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?/gi)];
  if (matches.length === 0) return {};
  const last = matches.at(-1);
  return {
    tests: Number(last[1]),
    failures: Number(last[2]),
  };
}

function parseNodeCounts(output) {
  const tests = output.match(/(?:ℹ|#)\s+tests?\s+(\d+)/i)?.[1];
  const passed = output.match(/(?:ℹ|#)\s+pass\s+(\d+)/i)?.[1];
  const failed = output.match(/(?:ℹ|#)\s+fail\s+(\d+)/i)?.[1];
  return {
    ...(tests ? { tests: Number(tests) } : {}),
    ...(passed ? { passed: Number(passed) } : {}),
    ...(failed ? { failed: Number(failed) } : {}),
  };
}

function withCounts(check, counts) {
  return Object.keys(counts).length > 0 ? { ...check, counts } : check;
}

const checks = [];

const swiftEnvironmentBlock = (output) =>
  /ModuleCache.*Operation not permitted|unable to load standard library|sandbox-exec: sandbox_apply: Operation not permitted/.test(output);
const swiftTest = commandCheck("swift_test", "swift", ["test"], {
  env: swiftChildEnv,
  blockedEnvironment: swiftEnvironmentBlock,
});
checks.push(withCounts(swiftTest, parseSwiftCounts(swiftTest.outputTail)));
checks.push(commandCheck("swift_build", "swift", ["build"], {
  env: swiftChildEnv,
  blockedEnvironment: swiftEnvironmentBlock,
}));
checks.push(commandCheck(
  "ios_simulator_build",
  "xcodebuild",
  [
    "-project", "SelfStudyStudio.xcodeproj",
    "-scheme", "SelfStudyStudio",
    "-sdk", "iphonesimulator",
    "-configuration", "Debug",
    "-derivedDataPath", "/tmp/self-study-studio-d1-derived-data",
    "CODE_SIGNING_ALLOWED=NO",
    "build",
  ],
  {
    env: swiftChildEnv,
    blockedEnvironment(output) {
      return /CoreSimulatorService|Simulator services will no longer be available|Connection refused/.test(output);
    },
  },
));

const webTest = commandCheck("web_test_and_build", "npm", ["test"], { cwd: webRoot });
checks.push(withCounts(webTest, parseNodeCounts(webTest.outputTail)));
checks.push(commandCheck("web_lint", "npm", ["run", "lint"], { cwd: webRoot }));
checks.push(commandCheck(
  "web_typecheck",
  "npm",
  ["exec", "--", "tsc", "--noEmit", "--incremental", "false"],
  {
    cwd: webRoot,
    knownBaseline(output, exitCode) {
      if (exitCode === 0) return false;
      const lines = output.split(/\r?\n/).filter((line) => /error TS\d+/.test(line));
      return lines.length > 0 && lines.every((line) =>
        /worker\/index\.ts.*Cannot find name 'Fetcher'/.test(line) ||
        /worker\/index\.ts.*Cannot find name 'D1Database'/.test(line),
      );
    },
  },
));
checks.push(commandCheck("git_diff_check", "git", ["diff", "--check"]));

checks.push(sourceCheck("swift_acceptance_manifest", [
  {
    file: "Tests/PersonalLearningJournalTests/JournalRecordContractTests.swift",
    patterns: ["testSharedFixturesCoverEveryJournalRecordKind", "testValidFixturesNormalizeThroughJournalEntityEncoding"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/CloudRecordMapperTests.swift",
    patterns: ["testEvidenceFirstEntitiesRoundTripAsStablePayloadRecords", "testPlanningEntitiesRoundTripInPrivateZone"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/ProjectStatusMigrationTests.swift",
    patterns: ["testMigrationCanonicalizesLowFrequencyAndTrashWithoutDroppingDependencies", "testMigrationWritesStatusBackupAndMarkerAndIsIdempotent"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/LearningPlanRevisionMigrationTests.swift",
    patterns: ["testDryRunAndExecuteMapLegacyRevisionIntegersToStableSeriesWithoutLoss"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/PracticeBlocksTests.swift",
    patterns: ["testPracticeSummaryCombinesRepeatedSegmentsAndExcludesPause", "testMultipleActiveRoutinesRequireExplicitMergeOrArchiveAndPreserveHistory"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/TodayAgendaServiceTests.swift",
    patterns: ["testMissedPlannedSessionBecomesCarryoverWithoutMovingItsWindow", "testAgendaIsDeterministicAndCombinesPlannedPracticeAndNextStep"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/PlanningWindowCapacityServiceTests.swift",
    patterns: ["testCapacityCheckAggregatesPlannedAndPracticeLoadByWeekAndProject", "testDSTAvailabilityUsesActualCalendarDuration"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/StageReviewServiceTests.swift",
    patterns: ["testStageReviewCannotAdvancePhaseWithoutExplicitQualifyingProof", "testStageReviewPublishesProofAndPhaseTransitionAtomicallyAndIdempotently", "testStageReviewPublicationRejectsStaleCapturedRevision"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/CloudSyncEndToEndTests.swift",
    patterns: ["testOfflineEditSurvivesRestartUploadsAndAppearsOnSecondRepository"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/SyncMergeServiceTests.swift",
    patterns: ["testDisjointProjectEditsMergeWithoutConflict", "testSameFieldProjectEditsCreateConflictWithoutDroppingEitherValue"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/PlanLifecycleGuardTests.swift",
    patterns: ["testOfflineCreateActivateReviseActivateKeepsPlanningDependencyChainTogether", "testOfflineRevisionLifecyclePassesStatefulProductionEquivalentBatchGuard"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/ProductConvergenceAcceptanceTests.swift",
    patterns: ["testEvidenceFirstLoopSurvivesTrashAndEncryptedArchiveRestore"],
  },
]));

checks.push(sourceCheck("swift_vnext_acceptance_manifest", [
  {
    file: "Tests/PersonalLearningJournalTests/VNextEndToEndTests.swift",
    patterns: [
      "testScenarioANewCourseDraftHiddenFromTodayUntilActivatedThenExactlyOneUpNext",
      "testScenarioBConfirmPublishesSessionAssessmentPlannedCompletionAndTrailInOneCommit",
      "testScenarioCSaveForLaterSurvivesStoreRecreationAndStaysOutOfJournalUntilConfirm",
      "testScenarioDAmendBumpsRevisionKeepsSnapshotAndLeavesPlanUntouched",
      "testScenarioEDetectAdoptNextStepAndStructuralRevisionLifecycle",
      "testScenarioFUnconfiguredAIStillCompletesLoopAndManualPlanAppearsInToday",
      "testLegacySnapshotDecodesLosslesslyWithoutFabricatedAssessments",
    ],
  },
  {
    file: "Tests/PersonalLearningJournalTests/PendingStudyCaptureStoreTests.swift",
    patterns: ["PendingStudyCaptureStore"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/LearningRecordServiceTests.swift",
    patterns: ["testConfirmCreatesSessionCompletesPlannedSessionAndAppliesNextStepInOneCommit", "testConfirmCommitFailureLeavesJournalUnchangedAndCapturePreserved"],
  },
  {
    file: "Tests/PersonalLearningJournalTests/LearningAdjustmentServiceTests.swift",
    patterns: ["testStructuralPrepareCreatesDraftKeepsBaseActiveAndNeverActivates", "testAdoptNextStepAppliesProjectTrailAndDecisionInOneCommit"],
  },
]));

checks.push(sourceCheck("web_acceptance_manifest", [
  {
    file: "WebWorkspace/app/workspace-app.tsx",
    patterns: ["const [dataMode, setDataMode]", "Real journal", "snapshot={dataMode === \"real\" ? realDashboardSnapshot : undefined}"],
  },
  {
    file: "WebWorkspace/tests/journal-contract.test.mjs",
    patterns: ["decodes every shared valid fixture with the same normalization", "keeps the existing CloudKit record-type names stable"],
  },
  {
    file: "WebWorkspace/tests/journal-reader-projector.test.mjs",
    patterns: ["CloudKit reader paginates", "Real CloudKit mode is explicitly blocked", "journal projector creates"],
  },
  {
    file: "WebWorkspace/tests/journal-write.test.mjs",
    patterns: ["writes an approved Next Step batch atomically", "stale writes return a conflict workspace", "plan activation sends base and new target records", "recoverable drafts survive a new store instance", "different-field edits merge", "Demo mode and unauthenticated Real mode never invoke CloudKit writes"],
  },
  {
    file: "WebWorkspace/lib/journal-writer.ts",
    patterns: ["ifServerRecordUnchanged", "semanticCommit", "savePlanRevisionDraft", "publishStageReview"],
  },
  {
    file: "WebWorkspace/lib/recoverable-drafts.ts",
    patterns: ["RecoverableDraftStore", "clearAfterCloudCompletion", "BrowserRecoverableDraftStore"],
  },
  {
    file: "WebWorkspace/lib/sync-conflicts.ts",
    patterns: ["mergeJournalPayloads", "resolveSyncConflict", "conflictingFields"],
  },
]));
checks.push(swiftAppTargetSourceParityCheck("swift_app_target_source_parity"));

const swiftReady = swiftTest.status === "PASS";
const webReady = webTest.status === "PASS";
const manifestsReady = checks
  .filter((check) => check.kind === "source-manifest")
  .every((check) => check.status === "PASS");
const localScenarioReady = swiftReady && webReady && manifestsReady;

const scenarioDefinitions = [
  {
    id: 1,
    title: "Manual Learning Plan activation appears across surfaces",
    evidence: ["CoursePlanningEndToEndTests.testActivatePlanStartPlannedSessionAndRecordProofCompletesTheLoop", "journal-write.test.mjs: plan activation sends base and new target records"],
    inputs: ["signed iPhone build", "same Apple Account", "provisioned CloudKit schema and zone", "Web token and allowed origin"],
  },
  {
    id: 2,
    title: "Practice Blocks appear in Today Agenda",
    evidence: ["TodayAgendaServiceTests.testAgendaIsDeterministicAndCombinesPlannedPracticeAndNextStep", "PracticeBlocksTests.testFlatRoutineMigratesToOneOrderedBlockWithoutChangingTargetOrIdentity"],
    inputs: ["physical iPhone Today surface", "same-owner CloudKit data"],
  },
  {
    id: 3,
    title: "Guided Routine Player records pause/skip/reorder/revisit timing",
    evidence: ["PracticeTimerEndToEndTests.testCreateStartPauseResumeAndSavePracticeWorkflow", "PracticeTimerRuntimeTests.testPauseExcludesWallClockAndFinishCombinesRevisitedBlockSegments"],
    inputs: ["physical iPhone with clock/audio interaction", "fresh app launch after saved session"],
  },
  {
    id: 4,
    title: "Practice Summary and optional Proof appear in Web Project Workspace",
    evidence: ["CloudRecordMapperTests.testPracticeSessionCloudRoundTripKeepsOptionalProjectLink", "journal-reader-projector.test.mjs: journal projector creates an existing workspace view model"],
    inputs: ["same-owner CloudKit records", "real asset download and browser preview"],
  },
  {
    id: 5,
    title: "Missed Planned Session becomes Carryover without rewriting its window",
    evidence: ["TodayAgendaServiceTests.testMissedPlannedSessionBecomesCarryoverWithoutMovingItsWindow"],
    inputs: ["physical iPhone Today interaction", "same-owner CloudKit convergence"],
  },
  {
    id: 6,
    title: "Capacity overload is visible and acknowledged activation remains possible",
    evidence: ["PlanningWindowCapacityServiceTests.testCapacityCheckAggregatesPlannedAndPracticeLoadByWeekAndProject", "CoursePlanningEndToEndTests.testActivatePlanStartPlannedSessionAndRecordProofCompletesTheLoop"],
    inputs: ["real availability and time-zone data", "manual activation confirmation on iPhone/Web"],
  },
  {
    id: 7,
    title: "Stage Review cannot advance without Qualifying Proof",
    evidence: ["StageReviewServiceTests.testStageReviewCannotAdvancePhaseWithoutExplicitQualifyingProof", "EvidenceFirstDomainTests.testReviewDecisionCompletionRequiresCapstoneProof"],
    inputs: ["same-owner Review and Proof records", "signed device or authenticated Web"],
  },
  {
    id: 8,
    title: "Published Review advances/revises exactly once and creates Trail events",
    evidence: ["StageReviewServiceTests.testStageReviewPublishesProofAndPhaseTransitionAtomicallyAndIdempotently", "JournalServiceTests.testTrailEventsCombineSessionsProofsNextStepAndStatusChangesNewestLast"],
    inputs: ["real CloudKit conditional write", "same-owner cross-surface refresh"],
  },
  {
    id: 9,
    title: "Different-field edits merge; same-field edits become Sync Conflict",
    evidence: ["SyncMergeServiceTests.testDisjointProjectEditsMergeWithoutConflict", "SyncMergeServiceTests.testSameFieldProjectEditsCreateConflictWithoutDroppingEitherValue", "journal-write.test.mjs: different-field edits merge"],
    inputs: ["two authenticated writers against one private zone", "manual conflict resolution UI"],
  },
  {
    id: 10,
    title: "Stale Plan activation/Review publication fails without overwrite",
    evidence: ["PlanLifecycleGuardTests.testOfflineRevisionLifecyclePassesStatefulProductionEquivalentBatchGuard", "StageReviewServiceTests.testStageReviewPublicationRejectsStaleCapturedRevision", "journal-write.test.mjs: stale writes return a conflict workspace"],
    inputs: ["real CloudKit change tags", "two-surface stale-write replay"],
  },
  {
    id: 11,
    title: "Project lifecycle archives history rather than deleting it",
    evidence: ["ProjectStatusMigrationTests.testMigrationCanonicalizesLowFrequencyAndTrashWithoutDroppingDependencies", "JournalArchiveServiceTests.testArchiveRoundTripRestoresRelationshipsAndAttachments", "ProductConvergenceMigrationTests.testExecutionRequiresExplicitAmbiguityResolutionsAndNeverInventsEvidence"],
    inputs: ["legacy production records", "signed app and archive/restore attachment verification"],
  },
  {
    id: 12,
    title: "Manual loop remains usable with Support Service and AI disabled",
    evidence: ["ProductConvergenceAcceptanceTests.testEvidenceFirstLoopSurvivesTrashAndEncryptedArchiveRestore", "ReviewServiceTests.testAdaptiveProviderUsesLocalReviewWhenAIIsNotConfigured"],
    inputs: ["human-run manual loop", "AI disabled, Support Service unavailable", "physical device and browser usability review"],
  },
];

const scenarios = scenarioDefinitions.map((scenario) => ({
  id: scenario.id,
  title: scenario.title,
  automated: {
    status: localScenarioReady ? "PASS_LOCAL_AUTOMATED" : "NOT_RUN",
    evidence: scenario.evidence,
    caveat: "Deterministic Swift/Web fakes and package tests; this is not same-owner live CloudKit/device evidence.",
  },
  manualLiveGate: {
    status: scenario.id === 12 ? "NOT_RUN" : "BLOCKED",
    requiredInputs: scenario.inputs,
    caveat: "Not inferred from Simulator, static tests, browser-independent Node tests, or local CloudKit fakes.",
  },
}));

// vNext (spec 2026-08-10 section 17) acceptance scenarios A–F. The automated
// evidence is the deterministic VNextEndToEndTests suite plus the targeted
// service tests; every scenario still has a REQUIRED MANUAL gate that this
// report never marks as passed.
const vnextScenarioDefinitions = [
  {
    id: "A",
    title: "New course: draft hidden from Today until activated, then exactly one Up Next",
    evidence: ["VNextEndToEndTests.testScenarioANewCourseDraftHiddenFromTodayUntilActivatedThenExactlyOneUpNext"],
    inputs: ["iPhone plan wizard walkthrough with editing and phase regeneration"],
  },
  {
    id: "B",
    title: "Complete a study: confirm publishes Session + assessment + planned completion + Trail in one commit",
    evidence: ["VNextEndToEndTests.testScenarioBConfirmPublishesSessionAssessmentPlannedCompletionAndTrailInOneCommit", "LearningRecordServiceTests.testConfirmCreatesSessionCompletesPlannedSessionAndAppliesNextStepInOneCommit"],
    inputs: ["physical iPhone guided study flow with real timer interaction"],
  },
  {
    id: "C",
    title: "Save-for-later recovery: pending capture survives relaunch and stays out of the journal until confirm",
    evidence: ["VNextEndToEndTests.testScenarioCSaveForLaterSurvivesStoreRecreationAndStaysOutOfJournalUntilConfirm"],
    inputs: ["system kill (jetsam/swipe-away) recovery of a pending capture on a physical device"],
  },
  {
    id: "D",
    title: "Record correction: amend bumps to revision 2, revision 1 snapshot viewable, plan untouched",
    evidence: ["VNextEndToEndTests.testScenarioDAmendBumpsRevisionKeepsSnapshotAndLeavesPlanUntouched"],
    inputs: ["iPhone record detail correction flow"],
  },
  {
    id: "E",
    title: "Adjustments: adopt a next-step suggestion in one commit; structural revision keeps v1 active until v2 activates",
    evidence: ["VNextEndToEndTests.testScenarioEDetectAdoptNextStepAndStructuralRevisionLifecycle", "LearningAdjustmentServiceTests.testStructuralPrepareCreatesDraftKeepsBaseActiveAndNeverActivates"],
    inputs: ["iPhone adjustment suggestion UI adopt/modify/ignore"],
  },
  {
    id: "F",
    title: "Degradation: unconfigured AI falls back to rule-based drafts and completes the loop; manual plan activates",
    evidence: ["VNextEndToEndTests.testScenarioFUnconfiguredAIStillCompletesLoopAndManualPlanAppearsInToday"],
    inputs: ["device run with AI unconfigured AND with a failing provider endpoint", "airplane-mode confirm"],
  },
];

const vnextScenarios = vnextScenarioDefinitions.map((scenario) => ({
  id: scenario.id,
  title: scenario.title,
  automated: {
    status: localScenarioReady ? "PASS_LOCAL_AUTOMATED" : "NOT_RUN",
    evidence: scenario.evidence,
    caveat: "Deterministic service-level tests over in-memory repositories and temp-dir stores; not device, notification, or CloudKit evidence.",
  },
  manualLiveGate: {
    status: "BLOCKED",
    requiredInputs: scenario.inputs,
    caveat: "Required manual acceptance; never inferred from Simulator runs or unit tests.",
  },
}));

const manualGates = [
  {
    id: "physical_device_signed_install",
    status: "BLOCKED",
    requiredInputs: ["connected and trusted iPhone/iPad", "Apple Developer Team", "signed installation", "CloudKit and Push entitlements"],
  },
  {
    id: "real_cloudkit_schema_token_origin",
    status: "BLOCKED",
    requiredInputs: ["provisioned development/production schema", "private zone", "Web API token", "allowed Web origins", "same Journal Owner"],
  },
  {
    id: "eventkit_real_calendar",
    status: "BLOCKED",
    requiredInputs: ["physical device", "Full Calendar Access", "writable target calendar", "manual preview and confirmation"],
  },
  {
    id: "attachments_and_cross_device_convergence",
    status: "BLOCKED",
    requiredInputs: ["two signed same-account devices or clean reinstall", "image/audio/document assets", "network recovery run"],
  },
  {
    id: "browser_visual_and_voiceover",
    status: "NOT_RUN",
    requiredInputs: ["interactive browser session", "responsive visual inspection", "VoiceOver/assistive-technology pass"],
  },
  {
    id: "manual_no_ai_loop",
    status: "NOT_RUN",
    requiredInputs: ["human run with Support Service and every AI capability disabled", "signed app and Web session"],
  },
];

// vNext REQUIRED MANUAL gates. These are never automated away: the
// deterministic suites above are service-level evidence only.
const vnextManualGates = [
  {
    id: "vnext_physical_device_cs336_flow",
    status: "BLOCKED",
    requiredInputs: ["signed physical iPhone install", "full CS336 flow: plan, study, confirm, amend, adjust"],
  },
  {
    id: "vnext_live_cloudkit_two_device_convergence",
    status: "BLOCKED",
    requiredInputs: ["two signed same-account devices", "confirmed records, revisions, and suggestions converge both ways"],
  },
  {
    id: "vnext_pending_capture_kill_recovery",
    status: "BLOCKED",
    requiredInputs: ["physical device", "system kill (jetsam/swipe-away) with a pending capture", "relaunch shows the recovery card without journal writes"],
  },
  {
    id: "vnext_local_notifications_and_deep_links",
    status: "BLOCKED",
    requiredInputs: ["physical device with notification permission", "pending-capture reminder fires", "deep link opens the pending confirmation"],
  },
  {
    id: "vnext_attachments_image_audio_file",
    status: "BLOCKED",
    requiredInputs: ["physical device", "image, audio, and file attachments staged in the guided flow", "download and preview after sync"],
  },
  {
    id: "vnext_max_dynamic_type",
    status: "NOT_RUN",
    requiredInputs: ["device or interactive inspection at the largest Dynamic Type size", "Today, study flow, and record draft screens remain usable"],
  },
  {
    id: "vnext_voiceover",
    status: "NOT_RUN",
    requiredInputs: ["VoiceOver pass over Today, completion check, record draft, and plan review"],
  },
  {
    id: "vnext_ai_unconfigured_and_provider_failure",
    status: "NOT_RUN",
    requiredInputs: ["device run with AI unconfigured", "device run against a failing provider endpoint", "airplane mode", "rule-based fallback completes the loop manually verifiable"],
  },
];

const knownBaselineCount = checks.filter((check) => check.status === "PASS_KNOWN_BASELINE").length;
const environmentBlockedCount = checks.filter((check) => check.status === "BLOCKED_ENVIRONMENT").length;
const failedCount = checks.filter((check) => check.status === "FAIL").length;
const blockedCount = manualGates.filter((gate) => gate.status === "BLOCKED").length;
const vnextBlockedCount = vnextManualGates.filter((gate) => gate.status === "BLOCKED").length;
const report = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  repository: {
    commit: gitCommit(),
    root: repoRoot,
  },
  automated: {
    status: failedCount > 0
      ? "FAIL"
      : environmentBlockedCount > 0
        ? "BLOCKED_ENVIRONMENT"
        : knownBaselineCount > 0
          ? "PASS_WITH_KNOWN_BASELINE"
          : "PASS",
    checks,
    summary: {
      total: checks.length,
      pass: checks.filter((check) => check.status === "PASS").length,
      knownBaseline: knownBaselineCount,
      environmentBlocked: environmentBlockedCount,
      fail: failedCount,
    },
  },
  scenarios,
  manualGates,
  vnext: {
    scenarios: vnextScenarios,
    manualGates: vnextManualGates,
    note: "vNext deterministic evidence comes from VNextEndToEndTests (scenarios A–F plus the legacy lossless-read fixture) and the targeted service suites; every listed manual gate remains REQUIRED and is not covered by automation.",
  },
  releaseGate: {
    status: failedCount > 0 || environmentBlockedCount > 0 || blockedCount > 0 || vnextBlockedCount > 0 ? "BLOCKED" : "PASS",
    blockedManualGates: blockedCount + vnextBlockedCount,
    note: "A PASS here would still require the listed manual gates; no physical-device, live CloudKit, EventKit, browser visual, or VoiceOver claim is made by this report.",
  },
};

if (reportPath) {
  mkdirSync(dirname(reportPath), { recursive: true });
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
}

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
} else {
  const automated = report.automated;
  process.stdout.write([
    `D1 release gate: ${report.releaseGate.status}`,
    `Automated checks: ${automated.status} (${automated.summary.pass} pass, ${automated.summary.knownBaseline} known-baseline, ${automated.summary.environmentBlocked} environment-blocked, ${automated.summary.fail} fail)`,
    `Scenarios: ${scenarios.filter((scenario) => scenario.automated.status === "PASS_LOCAL_AUTOMATED").length}/12 deterministic local coverage; ${blockedCount} manual gates blocked; ${manualGates.filter((gate) => gate.status === "NOT_RUN").length} not run`,
    `vNext scenarios: ${vnextScenarios.filter((scenario) => scenario.automated.status === "PASS_LOCAL_AUTOMATED").length}/6 deterministic local coverage; ${vnextBlockedCount} vNext manual gates blocked; ${vnextManualGates.filter((gate) => gate.status === "NOT_RUN").length} not run`,
    reportPath ? `Machine-readable report: ${reportPath}` : "Use --json or --report <path> for machine-readable output.",
  ].join("\n") + "\n");
}

if (report.releaseGate.status === "BLOCKED" && !allowBlocked) process.exitCode = 2;
if (report.automated.status === "FAIL") process.exitCode = 1;
