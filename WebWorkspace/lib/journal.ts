export type WorkspaceSection =
  | "dashboard"
  | "projects"
  | "project"
  | "reviews"
  | "sync";

export type ProjectTab =
  | "overview"
  | "plan"
  | "practice"
  | "proof"
  | "trail"
  | "reviews";

export type ProjectSummary = {
  id: string;
  token: string;
  name: string;
  area: string;
  goal: string;
  phase: string;
  phaseWindow: string;
  status: "Active" | "Paused" | "Completed" | "Abandoned";
  accent: string;
  nextStep: string;
  expectedProof: string;
  evidenceCount: number;
  evidenceTarget: number;
  lastMeaningfulActivity: string;
};

export type PracticeBlock = {
  id: string;
  name: string;
  targetMinutes: number;
  actualMinutes: number;
  focus: string;
  nextFocus: string;
  tone: "coral" | "blue" | "green";
};

export type TrailItem = {
  id: string;
  date: string;
  occurredAt: string;
  title: string;
  detail: string;
  kind: "practice" | "proof" | "plan" | "review";
};

export type PlanSession = {
  id: string;
  title: string;
  window: string;
  duration: number;
  status: "Done" | "Planned" | "Carryover";
  attentionAt?: string;
};

export type PlanPhase = {
  id: string;
  order: number;
  title: string;
  description: string;
  window: string;
  status: "Complete" | "Active" | "Planned";
  milestones: string[];
};

export type ProofItem = {
  id: string;
  kind: "Audio" | "Code" | "Diagram" | "Text";
  status: string;
  title: string;
  detail: string;
  date: string;
  preview: string;
  previewDetail: string;
};

export type ProjectDemo = {
  project: ProjectSummary;
  sourceLabel: string;
  planTitle: string;
  planRevision: number;
  planPhases: PlanPhase[];
  sessions: PlanSession[];
  routineTitle: string;
  routineFrequency: string;
  routineTargetMinutes: number;
  practiceBlocks: PracticeBlock[];
  practiceBalanceNote: string;
  practiceAttention?: {
    id: string;
    label: string;
    detail: string;
    markedAt: string;
  };
  lastSessionLabel: string;
  trail: TrailItem[];
  proofs: ProofItem[];
  review: {
    ready: boolean;
    headline: string;
    summary: string;
    practiceSessions: number;
    carryovers: number;
    readySince: string;
    readySinceAt?: string;
  };
  capacity: {
    plannedMinutes: number;
    availableMinutes: number;
    note: string;
  };
};

const guitarDemo: ProjectDemo = {
  project: {
    id: "electric-guitar-improvisation",
    token: "EG",
    name: "Electric guitar improvisation",
    area: "Music",
    goal: "Improvise melodic phrases over a backing track without a score or a memorized solo, with rhythm, space, and emotional direction.",
    phase: "Rhythm + root awareness",
    phaseWindow: "Weeks 1–2 of 12",
    status: "Active",
    accent: "#eb5b4f",
    nextStep: "Use only A, C, and D over an A-minor backing track for 5 minutes, leaving space after every phrase.",
    expectedProof: "A one-minute recording with steady time, 3–5 note phrases, intentional rests, and a natural resolution to A.",
    evidenceCount: 1,
    evidenceTarget: 3,
    lastMeaningfulActivity: "Guided practice · 31 min · yesterday",
  },
  sourceLabel: "Demo source · Electric Guitar Improvisation Learning Guide",
  planTitle: "12-week electric guitar improvisation foundation",
  planRevision: 1,
  planPhases: [
    {
      id: "guitar-1",
      order: 1,
      title: "Rhythm and root awareness",
      description: "Locate common roots, stabilize eighth notes, and make short phrases with only A, C, and D.",
      window: "Weeks 1–2",
      status: "Active",
      milestones: ["6th- and 5th-string roots", "A minor pentatonic box 1", "Three-note phrases with rests"],
    },
    {
      id: "guitar-2",
      order: 2,
      title: "Blues scale and basic articulation",
      description: "Add the blues note, slides, hammer-ons, pull-offs, and simple call and response.",
      window: "Weeks 3–4",
      status: "Planned",
      milestones: ["A blues scale", "D–E♭–E passing phrase", "Recorded call and response"],
    },
    {
      id: "guitar-3",
      order: 3,
      title: "Bending and vibrato",
      description: "Build reliable half- and whole-step bends, then sustain long notes with controlled vibrato.",
      window: "Weeks 5–6",
      status: "Planned",
      milestones: ["Target-pitch bends", "Four-beat sustained notes", "Five-minute bend recording"],
    },
    {
      id: "guitar-4",
      order: 4,
      title: "12-bar blues harmony",
      description: "Hear I–IV–V movement and land phrases deliberately over A7, D7, and E7.",
      window: "Weeks 7–8",
      status: "Planned",
      milestones: ["12-bar form", "Chord-root pass", "Target-note choices"],
    },
    {
      id: "guitar-5",
      order: 5,
      title: "Lick vocabulary and variation",
      description: "Learn five blues licks and transform their rhythm, key, and ending note.",
      window: "Weeks 9–10",
      status: "Planned",
      milestones: ["Five analyzed licks", "Three variations each", "Transpose to E minor"],
    },
    {
      id: "guitar-6",
      order: 6,
      title: "Complete improvised statement",
      description: "Shape themes and tension across a complete 12-bar solo, then review the recording.",
      window: "Weeks 11–12",
      status: "Planned",
      milestones: ["Four-bar phrases", "Theme development", "Weekly comparison recording"],
    },
  ],
  sessions: [
    { id: "guitar-session-1", title: "Map A, C, D, E, G roots", window: "Completed Monday", duration: 15, status: "Done" },
    { id: "guitar-session-2", title: "Three-note call and response", window: "Today", duration: 30, status: "Planned" },
    { id: "guitar-session-3", title: "Listen back and mark unstable phrases", window: "Due yesterday", duration: 15, status: "Carryover", attentionAt: "2026-07-22T00:00:00Z" },
  ],
  routineTitle: "30-minute improvisation foundation",
  routineFrequency: "5 times each week",
  routineTargetMinutes: 30,
  practiceBlocks: [
    { id: "guitar-warmup", name: "Rhythm warm-up", targetMinutes: 5, actualMinutes: 5, focus: "Alternate picking at 60 BPM", nextFocus: "Keep eighth notes relaxed", tone: "blue" },
    { id: "guitar-fretboard", name: "Fretboard + scale", targetMinutes: 5, actualMinutes: 6, focus: "A, C, D, E, G roots and box 1", nextFocus: "Name each root before playing", tone: "green" },
    { id: "guitar-technique", name: "Expression technique", targetMinutes: 5, actualMinutes: 4, focus: "Clean slides into target notes", nextFocus: "Add half-step bend accuracy", tone: "coral" },
    { id: "guitar-improv", name: "Backing-track phrases", targetMinutes: 10, actualMinutes: 11, focus: "Only A, C, D; phrase then rest", nextFocus: "Repeat one motif with a new ending", tone: "coral" },
    { id: "guitar-review", name: "Record + listen", targetMinutes: 5, actualMinutes: 5, focus: "Mark timing, noise, landing, emotion", nextFocus: "Keep one best phrase as proof", tone: "blue" },
  ],
  practiceBalanceNote: "The routine gives most time to musical sentences; expression technique is slightly below guidance.",
  lastSessionLabel: "Yesterday at 20:14 · all five Blocks visited.",
  trail: [
    { id: "guitar-trail-1", date: "Yesterday · 20:14", occurredAt: "2026-07-22T12:14:00Z", title: "Improvisation foundation practice", detail: "31 min · rhythm 5m · fretboard 6m · technique 4m · phrases 11m · review 5m", kind: "practice" },
    { id: "guitar-trail-2", date: "Jul 20 · 20:48", occurredAt: "2026-07-20T12:48:00Z", title: "Three-note improvisation added", detail: "Proof: steady opening, but the second phrase rushes ahead of the backing track.", kind: "proof" },
    { id: "guitar-trail-3", date: "Jul 18 · 19:30", occurredAt: "2026-07-18T11:30:00Z", title: "Minimum executable routine selected", detail: "Five guided Blocks created from the 30-minute daily template.", kind: "plan" },
    { id: "guitar-trail-4", date: "Jul 15 · 09:12", occurredAt: "2026-07-15T01:12:00Z", title: "12-week plan activated", detail: "Revision 1 · 6 two-week phases · weekly comparison recording enabled.", kind: "review" },
  ],
  proofs: [
    { id: "guitar-proof-1", kind: "Audio", status: "candidate proof", title: "A-minor three-note improvisation", detail: "One minute using only A, C, and D. The first phrase has clear space and resolves naturally to A.", date: "Jul 20", preview: "01:00", previewDetail: "▂▅▃▇▄▂▁▅▃▇▅▂▆" },
    { id: "guitar-proof-2", kind: "Text", status: "practice note", title: "Listening checklist", detail: "Review timing, string noise, landing notes, repetition, variation, and emotional contour.", date: "Jul 18", preview: "6 checks", previewDetail: "TIME · NOISE · LANDING" },
  ],
  review: {
    ready: true,
    headline: "Rhythm + root awareness",
    summary: "Decide whether the recording shows steady pulse, intentional rests, and reliable root resolution before adding more notes.",
    practiceSessions: 5,
    carryovers: 1,
    readySince: "Ready since yesterday",
    readySinceAt: "2026-07-22T00:00:00Z",
  },
  capacity: {
    plannedMinutes: 210,
    availableMinutes: 240,
    note: "30 minutes remains available for one optional listening session.",
  },
};

const cs336Demo: ProjectDemo = {
  project: {
    id: "cs336",
    token: "CS",
    name: "CS336 · Language Modeling from Scratch",
    area: "Computer science",
    goal: "Understand the full LLM training chain and build the core tokenizer, Transformer, and training loop from first principles.",
    phase: "Tokenizer + Transformer foundations",
    phaseWindow: "Weeks 3–6 of 20",
    status: "Active",
    accent: "#356bc7",
    nextStep: "Implement the BPE merge loop on a small bilingual corpus and record the first benchmark.",
    expectedProof: "A reversible tokenizer with passing fixtures, benchmark notes, and a short explanation of vocabulary tradeoffs.",
    evidenceCount: 2,
    evidenceTarget: 4,
    lastMeaningfulActivity: "Build session · 52 min · 3 days ago",
  },
  sourceLabel: "Demo source · CS336 20-week Online Self-study Plan",
  planTitle: "CS336 20-week core route",
  planRevision: 1,
  planPhases: [
    { id: "cs-phase-1", order: 1, title: "Build the global map", description: "Understand the learning-plan position, language-model objective, and end-to-end training pipeline.", window: "Weeks 1–2", status: "Complete", milestones: ["CS336 overview and LLM production flow", "Language-model objective and perplexity"] },
    { id: "cs-phase-2", order: 2, title: "Tokenizer + Transformer foundations", description: "Turn text into token IDs and assemble a Transformer that can run forward and compute loss.", window: "Weeks 3–6", status: "Active", milestones: ["Tokenizer and BPE", "Embedding, RoPE, RMSNorm", "Causal self-attention", "MLP, LM head, complete forward"] },
    { id: "cs-phase-3", order: 3, title: "Training loop + Assignment 1", description: "Train, checkpoint, sample, debug, and explain a complete small language-model system.", window: "Weeks 7–10", status: "Planned", milestones: ["Optimizer and training loop", "Checkpoint and sampling", "Assignment 1 integration", "Assignment 1 system summary"] },
    { id: "cs-phase-4", order: 4, title: "Systems: FLOPs, memory, GPU, profiling", description: "Estimate training cost, locate bottlenecks, and understand practical memory optimizations.", window: "Weeks 11–14", status: "Planned", milestones: ["Resource accounting", "GPU and PyTorch profiling", "Memory optimization", "Assignment 2 systems map"] },
    { id: "cs-phase-5", order: 5, title: "FlashAttention, Triton, distributed training", description: "Understand IO-aware attention and the dimensions along which large training jobs are parallelized.", window: "Weeks 15–16", status: "Planned", milestones: ["FlashAttention and Triton", "Distributed training strategies"] },
    { id: "cs-phase-6", order: 6, title: "Scaling laws", description: "Relate model size, data, tokens, and compute under a fixed training budget.", window: "Weeks 17–18", status: "Planned", milestones: ["Scaling-law foundations", "Compute-optimal training"] },
    { id: "cs-phase-7", order: 7, title: "Pre-training data", description: "Map the path from raw web content to filtered, deduplicated, mixed training corpora.", window: "Week 19", status: "Planned", milestones: ["Extraction, filtering, deduplication, contamination, mixture"] },
    { id: "cs-phase-8", order: 8, title: "Post-training + alignment", description: "Distinguish SFT, RLHF, DPO, RLVR, and safety alignment in the model lifecycle.", window: "Week 20", status: "Planned", milestones: ["Base vs chat models", "Preference optimization", "Final system summary"] },
  ],
  sessions: [
    { id: "cs-session-1", title: "Explain BPE merge mechanics", window: "Completed Tuesday", duration: 40, status: "Done" },
    { id: "cs-session-2", title: "Implement BPE training loop", window: "Tonight", duration: 60, status: "Planned" },
    { id: "cs-session-3", title: "Add encode/decode round-trip fixtures", window: "This weekend", duration: 60, status: "Planned" },
  ],
  routineTitle: "CS336 focused build session",
  routineFrequency: "5 times each week",
  routineTargetMinutes: 60,
  practiceBlocks: [
    { id: "cs-recall", name: "Recall + scope", targetMinutes: 10, actualMinutes: 8, focus: "Restate BPE input, output, and stopping rule", nextFocus: "Write the merge invariant first", tone: "blue" },
    { id: "cs-build", name: "Deep implementation", targetMinutes: 40, actualMinutes: 38, focus: "Implement pair counts and the merge loop", nextFocus: "Benchmark incremental pair updates", tone: "coral" },
    { id: "cs-log", name: "Learning log", targetMinutes: 10, actualMinutes: 6, focus: "Record bugs, next step, and unresolved questions", nextFocus: "Explain vocabulary-size tradeoffs", tone: "green" },
  ],
  practiceBalanceNote: "Implementation is on target; the learning log needs four more minutes to preserve reasoning and next-step context.",
  practiceAttention: {
    id: "learning-log-balance",
    label: "Learning log needs attention",
    detail: "The last session left four minutes of the Learning log block unvisited.",
    markedAt: "2026-07-19T02:20:00Z",
  },
  lastSessionLabel: "Sunday at 10:20 · all three Blocks visited.",
  trail: [
    { id: "cs-trail-1", date: "Jul 19 · 10:20", occurredAt: "2026-07-19T02:20:00Z", title: "BPE implementation session", detail: "52 min · recall 8m · build 38m · learning log 6m", kind: "practice" },
    { id: "cs-trail-2", date: "Jul 19 · 11:14", occurredAt: "2026-07-19T03:14:00Z", title: "BPE merge diagram added", detail: "Proof connects corpus pair counts, merge selection, vocabulary growth, encode, and decode.", kind: "proof" },
    { id: "cs-trail-3", date: "Jul 14 · 20:40", occurredAt: "2026-07-14T12:40:00Z", title: "Global-map stage reviewed", detail: "Advanced after explaining the LLM pipeline and next-token objective without notes.", kind: "review" },
    { id: "cs-trail-4", date: "Jul 1 · 09:00", occurredAt: "2026-07-01T01:00:00Z", title: "20-week core route activated", detail: "Revision 1 · 8 stages · 6–8 hours available each week.", kind: "plan" },
  ],
  proofs: [
    { id: "cs-proof-1", kind: "Diagram", status: "accepted signal", title: "LLM training pipeline map", detail: "Raw text → tokenizer → Transformer LM → pre-training → evaluation → post-training → assistant.", date: "Jul 12", preview: "7 stages", previewDetail: "TEXT → TOKENS → MODEL" },
    { id: "cs-proof-2", kind: "Code", status: "candidate proof", title: "BPE merge loop", detail: "Pair counting and deterministic merge selection work on a small bilingual fixture; encode/decode remains next.", date: "Jul 19", preview: "18 tests", previewDetail: "PAIR → MERGE → VOCAB" },
  ],
  review: {
    ready: false,
    headline: "Tokenizer + Transformer foundations",
    summary: "The phase remains active until the tokenizer is reversible and the first Transformer forward pass produces a valid loss.",
    practiceSessions: 3,
    carryovers: 0,
    readySince: "Review opens after 4 proof signals",
  },
  capacity: {
    plannedMinutes: 390,
    availableMinutes: 480,
    note: "90 minutes remains for the weekend tokenizer benchmark and review.",
  },
};

export const projectDemos: ProjectDemo[] = [guitarDemo, cs336Demo];
export const projects = projectDemos.map((demo) => demo.project);

export function getProjectDemo(projectId: string): ProjectDemo {
  return projectDemos.find((demo) => demo.project.id === projectId) ?? projectDemos[0];
}
