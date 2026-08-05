# Observation and Startup Recovery Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use test-driven development and execute each checkbox in order.

**Goal:** Make Codex rollout observation bounded, incremental, privacy-safe, and fail-closed while recovering only recent unresolved attention at startup.

**Architecture:** `CodexRolloutMonitor` remains the sole rollout reader. It will discover a bounded recent candidate set, inspect startup files within per-file and aggregate byte budgets, seed only unresolved attention correlation, and tail later appends by cursor. Numeric-only poll metrics make I/O and memory bounds testable without exposing event payloads; the app keeps its one-second refresh loop and downgrades observation failures to existing fallback-only/unavailable UI states.

**Tech Stack:** Swift 6, Foundation file APIs, Swift Testing, Swift Package Manager, AppKit/SwiftUI.

---

### Task 1: Startup Recovery Contract

**Files:**
- Modify: `Tests/HealthTokenCoreTests/CodexRolloutMonitorTests.swift`
- Modify: `Sources/HealthTokenCore/CodexRolloutMonitor.swift`

- [ ] **Step 1: Write failing startup tests**

Add fixtures with timestamped `request_user_input` / approval records and matching output, terminal, stale, malformed, partial, oversized, and out-of-order variants. Assert startup emits exactly one content-free `.attentionChanged/.required` only when at least one recent request remains unresolved, and emits no Subagent/session/tool event from history.

- [ ] **Step 2: Verify RED**

Run `swift test --filter CodexRolloutMonitorTests` and confirm unresolved-attention recovery fails while the historical Subagent test exposes the prohibited replay.

- [ ] **Step 3: Implement minimal startup inspection**

Replace startup Subagent restoration with bounded prefix/tail inspection. Require a valid root session context, recent monotonic record timestamps, request IDs, and no matching resolution/terminal record; seed `AttentionCorrelation` with opaque IDs in memory and return only a normalized attention-required event stamped with `observedAt`.

- [ ] **Step 4: Verify GREEN**

Run `swift test --filter CodexRolloutMonitorTests` and confirm all startup tests pass.

### Task 2: Bounded Incremental Observation

**Files:**
- Modify: `Tests/HealthTokenCoreTests/CodexRolloutMonitorTests.swift`
- Modify: `Sources/HealthTokenCore/CodexRolloutMonitor.swift`

- [ ] **Step 1: Write failing budget and cursor tests**

Configure small limits and assert candidate count, candidate age, scanned-entry count, per-file bytes, aggregate bytes, record bytes, pending-request count, and retained remainder are bounded. Assert unchanged files report zero reads/parses and later polls read only appended bytes.

- [ ] **Step 2: Verify RED**

Run `swift test --filter CodexRolloutMonitorTests` and confirm the missing limits/metrics and aggregate budget assertions fail.

- [ ] **Step 3: Implement limits and metrics**

Add a public immutable limits value with production defaults and a numeric-only `lastPollMetrics`. Apply age filtering during discovery, enforce per-file and total read budgets on every prefix/tail/incremental read, bound partial-record and pending-ID memory, and drop C-capable session state on ambiguous oversized input.

- [ ] **Step 4: Verify GREEN and latency**

Run `swift test --filter CodexRolloutMonitorTests`; a representative synthetic active-file fixture must finish rollout polling within one second, leaving the one-second UI timer inside the two-second presentation SLA.

### Task 3: Privacy and Fallback Health

**Files:**
- Modify: `Tests/HealthTokenCoreTests/AgentEventAdapterTests.swift`
- Modify: `Tests/HealthTokenCoreTests/CodexEventInboxTests.swift`
- Modify: `Tests/HealthTokenCoreTests/FileHydrationStoreTests.swift`
- Modify: `Tests/HealthTokenCoreTests/CodexHookInstallerTests.swift`
- Modify: `Sources/HealthTokenApp/HydrationAppModel.swift`
- Modify: `Sources/HealthTokenApp/HealthTokenApp.swift`

- [ ] **Step 1: Write failing privacy/fallback assertions**

Audit encoded normalized events, inbox files, monitor metrics, hydration persistence, and generic diagnostics against sentinel prompt/code/tool-argument/assistant-output/secret values. Assert observation failure cannot report connected and never prevents `.timeAdvanced` fallback hydration behavior.

- [ ] **Step 2: Verify RED**

Run the focused Core tests and confirm any newly required status downgrade or shared poll interval fails before implementation.

- [ ] **Step 3: Implement minimal app integration changes**

Use the shared one-second observation interval in the app timer. When rollout/inbox observation throws, preserve the existing generic error, continue `.timeAdvanced`, and compute fallback-only/unavailable health without treating a previously recent hook event as connected.

- [ ] **Step 4: Verify GREEN**

Run the focused privacy, installer, store, and hydration tests and confirm no private sentinel appears in encoded or persisted output.

### Task 4: Documentation, Verification, Review, Commit

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document exact operational bounds**

State the startup/steady-state candidate count, candidate age, directory-entry scan ceiling, per-file/aggregate/record byte limits, pending correlation and remainder memory bounds, one-second poll cadence, recovery proof rules, and fallback behavior.

- [ ] **Step 2: Run complete verification**

Run `swift test --disable-index-store` and `./scripts/build-app.sh release`; record the total passing test count and the generated Release app path.

- [ ] **Step 3: Review against repository standards and Issue #8**

Review `git diff origin/main...HEAD` (or the working-tree diff before commit) for privacy leakage, unbounded reads/state, startup C replay, #9 scope creep, and documented-code mismatches. Fix every concrete finding and rerun affected tests.

- [ ] **Step 4: Commit**

Stage all Issue #8 files and commit with `fix: harden Codex observation recovery (#8)`. Confirm the branch is clean and only Issue #9 remains open after this implementation slice; do not close or modify Issue #9.
