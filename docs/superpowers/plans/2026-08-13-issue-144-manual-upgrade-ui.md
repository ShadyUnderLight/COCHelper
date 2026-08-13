# Issue 144 Manual Upgrade UI Implementation Plan

> **For agentic workers:** This plan is executed in the isolated worktree `feat/issue-144-manual-upgrade-ui` from `origin/main@c295f86`.

**Goal:** Connect the existing local manual-upgrade Core, effective projection, persistence, and reconciliation layers to a safe macOS SwiftUI workflow for starting, cancelling, adjusting, filtering, and reviewing local upgrade records.

**Architecture:** Add a Core-only canonical action and display projection. All top-level non-nested tracker items can expose a quantity-one start action when the Core gates pass; duplicate buildings/walls reuse their aggregate distribution, while nested items and Craft Table remain read-only. AppModel owns typed commands and revalidates the current village, snapshot baseline, storage state, and freshly rebuilt action before mutating the persisted tracker. Views only render projections and invoke AppModel callbacks.

**Tech Stack:** Swift 6, SwiftUI/macOS 14, Foundation, XCTest, existing `ManualUpgradeCore`, `ManualTrackerStore`, `VillageCatalogProjection`, and `BuildingGroupProjection`.

---

## Task 1: Canonical action and filter projections

**Files:**
- Create: `Sources/COCHelperCore/UpgradeActionProjection.swift`
- Create: `Tests/COCHelperCoreTests/UpgradeActionProjectionTests.swift`
- Modify: `Sources/COCHelperCore/BuildingGroupProjection.swift`

- [ ] Write tests for all top-level categories, nested/Craft Table read-only, unknown/partial/lifecycle/baseline gates, unknown cost non-blocking, and deterministic filter/search/sort.
- [ ] Run the focused test file and verify the expected missing-type failures.
- [ ] Implement `UpgradeAction`, `UpgradeActionProjection`, `UpgradeDisplayState`, and `UpgradeDisplayFilter` as pure Core types.
- [ ] Make the projection derive stable `TrackerItemKey`, effective distribution, catalog target level, duration, costs, provenance, and disabled reasons without mutating state.
- [ ] Adapt `BuildingGroupUpgradeAction` to the canonical action fields while preserving existing callers and duplicate quantity-one semantics.
- [ ] Run focused Core tests and the existing `BuildingGroupProjectionTests`.

## Task 2: AppModel typed commands and revalidation

**Files:**
- Modify: `Sources/COCHelperApp/AppModel.swift`
- Modify: `Tests/COCHelperCoreTests/ManualTrackerStoreTests.swift`
- Create: `Tests/COCHelperCoreTests/AppModelManualUpgradeCommandTests.swift`

- [ ] Write failing tests for typed Start/Cancel/Adjust commands, stale action rejection, explicit village routing, unknown cost acceptance, unavailable store rejection, instant completion, and persistence failure behavior.
- [ ] Run the focused tests and verify failures are caused by missing typed commands.
- [ ] Add typed `startManualUpgrade`, `cancelManualUpgrade`, and `adjustManualUpgradeStart` methods.
- [ ] Rebuild the current projection inside Start and compare the supplied action identity, baseline, target, duration, quantity, and village before calling `updateManualUpgradeCore`.
- [ ] Reuse `ManualUpgradeCore` for all state transitions and existing transaction/store error handling.
- [ ] Run AppModel and manual tracker tests.

## Task 3: Overview state projection and settlement lifecycle

**Files:**
- Modify: `Sources/COCHelperCore/UpgradeOverviewProjection.swift`
- Modify: `Tests/COCHelperCoreTests/UpgradeOverviewProjectionTests.swift`
- Modify: `Sources/COCHelper/ContentView.swift`
- Modify: `Sources/COCHelper/COCHelperApp.swift`

- [ ] Write failing tests for manual/imported active counts, exact deduplicated display rows, possible duplicate/conflict parallel rows, seven-day completed recency, and deterministic state filtering.
- [ ] Add a Core overview state projection that retains provenance and record-level counts separately from duplicate quantity.
- [ ] Keep the existing active/pending API source-compatible while adding the new state buckets.
- [ ] Add one scene-active settlement hook at the root and retain the existing 60-second active refresh path.
- [ ] Ensure search/filter/sort only consumes already-built projection values and never persists.
- [ ] Run overview, AppModel, and content-related compile checks.

## Task 4: Village Detail, group cards, and shared row controls

**Files:**
- Modify: `Sources/COCHelper/VillageDetailView.swift`
- Modify: `Sources/COCHelper/ContentView.swift`
- Modify: `Sources/COCHelper/UpgradeDisplayRow.swift`
- Modify: `Sources/COCHelper/BuildingGroupCard.swift`
- Create: `Sources/COCHelper/ManualUpgradeConfirmationView.swift`

- [ ] Add shared callbacks and state for Start confirmation, Cancel confirmation, and Adjust start time.
- [ ] Render canonical action availability and disabled reasons on ordinary rows and duplicate group cards.
- [ ] Keep nested and Craft Table rows read-only while allowing search/filter/status display.
- [ ] Display stable identity, level transition, quantity, costs including raw/unknown details, duration, catalog provenance, and local-only warning in confirmation UI.
- [ ] Route every action with explicit `villageID`; never use the selected village as a hidden command target.
- [ ] Add accessibility labels and disabled reasons for action controls.
- [ ] Run `swift build` and focused Core/AppModel tests after UI compilation changes.

## Task 5: Verification and PR

**Files:**
- Modify only files required by the implementation and tests above.

- [ ] Run `swift test` and record the complete pass count.
- [ ] Run `swift build -c release`.
- [ ] Run `./scripts/build_app.sh`.
- [ ] Run `git diff --check` and inspect the complete diff against `origin/main`.
- [ ] Run focused mutation-style probes for action gates and two-village routing if any test gap remains.
- [ ] Commit the implementation in focused commits, push `feat/issue-144-manual-upgrade-ui`, and create a PR toward `main` for user review without merging it.
