# Issue 164 Coverage Universe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent Snapshot History from treating parseable or empty sections as proof of complete source coverage, so incomplete imports cannot create confirmed deletions or quantity decreases.

**Architecture:** Keep field-level parse coverage separate from section/universe completeness. The canonicalizer records immutable section presence, completeness, and proof metadata; the current account JSON adapter supplies no completeness proof by default. Diff gates absence and histogram changes on that frozen section proof, while observed item field changes retain their existing behavior. Legacy coverage records remain readable but are treated as unavailable for absence-based decisions.

**Tech Stack:** Swift 6 / Foundation Codable / XCTest / Swift Package Manager.

---

### Task 1: Add failing canonicalizer and Diff regressions

**Files:**
- Modify: `Tests/COCHelperCoreTests/SnapshotHistoryCoreTests.swift`
- Modify: `Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift`

- [ ] Add tests proving a present-empty and present-nonempty account section have explicit presence but no complete universe proof by default.
- [ ] Add a real canonicalizer regression for `item -> empty section`: the Diff must produce `unknown`, never confirmed `noLongerObserved`.
- [ ] Add a real canonicalizer regression for `count 5 -> count 3`: the histogram Diff must produce `unknown`, never confirmed quantity change.
- [ ] Run the new tests and confirm they fail against the current `presence = complete` behavior.

### Task 2: Persist section completeness evidence

**Files:**
- Modify: `Sources/COCHelperCore/SnapshotHistoryModels.swift`
- Modify: `Sources/COCHelperCore/SnapshotHistoryCanonicalizer.swift`

- [ ] Add Codable section presence/completeness/evidence types with deterministic sorting and no secret-bearing fields.
- [ ] Bump the observation schema version and make `SnapshotObservationCoverage` decode old records with missing section evidence as legacy coverage.
- [ ] Add an optional explicit proof map to canonicalization. The current account JSON path defaults to unknown/unavailable completeness; only an injected source proof can authorize complete-empty or complete-nonempty.
- [ ] Keep field parse validation unchanged for observed level/count/timer values; only section/universe absence semantics become conservative.
- [ ] Include section evidence in the immutable entry integrity material so later mutation is rejected.
- [ ] Run canonicalizer/core tests and verify the new regressions pass.

### Task 3: Gate Diff absence and histogram decisions

**Files:**
- Modify: `Sources/COCHelperCore/SnapshotHistoryDiff.swift`
- Modify: `Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift`

- [ ] Require complete section proof for confirmed `newlyObserved`/`noLongerObserved` decisions.
- [ ] Require complete section proof for histogram migration and quantity changes; preserve existing deterministic ordering and aggregate evidence.
- [ ] Emit structured insufficient-coverage diagnostics when section proof is missing or legacy.
- [ ] Keep direct observed unique level/timer changes available when their field-level evidence is complete.
- [ ] Add tests for explicit authoritative complete-empty proof, legacy coverage, and home/builder section isolation.

### Task 4: Preserve legacy history safely

**Files:**
- Modify: `Sources/COCHelperCore/SnapshotHistoryStore.swift`
- Modify: `Tests/COCHelperCoreTests/SnapshotHistoryStoreTests.swift`

- [ ] Accept the previous observation version for reading and validation without backfilling it from the current catalog.
- [ ] Ensure legacy entries remain integrity-checked and are exposed to Diff as unavailable section completeness.
- [ ] Reject unsupported future versions and coverage tampering as before.
- [ ] Add Codable/migration tests proving legacy raw JSON, display binding, and integrity remain frozen.

### Task 5: Full verification and delivery

**Files:**
- Review only: all changed files and current worktree diff.

- [ ] Run Snapshot History tests, full `swift test`, `swift build -c release`, `./scripts/build_app.sh`, and `git diff --check`.
- [ ] Inspect `git status`, `git diff`, and recent log; commit only intended Issue 164 files.
- [ ] Push `issue-164-coverage-universe` and create a PR describing the fail-closed behavior, legacy handling, tests, and known source-proof boundary.
- [ ] Stop after PR creation so the user can review; do not merge.
