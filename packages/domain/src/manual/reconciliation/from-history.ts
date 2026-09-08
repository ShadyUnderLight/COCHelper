/**
 * SnapshotHistory entry / import decision → ManualReconciliationEvidence。
 * 对齐 Swift ManualTrackerReconciliationService.observations(in:) / reference(for:in:)。
 */

import { INT64_MAX, refSecondsToUnixSeconds, saturatingAdd } from '@coc-helper/wire';
import type { UuidString } from '@coc-helper/wire';

import { SnapshotDiffEngine } from '../../snapshot-history/diff-engine';
import type { SnapshotChange } from '../../snapshot-history/diff-types';
import { SNAPSHOT_HISTORY_TIMER_FIELDS } from '../../snapshot-history/known-sections';
import type { SnapshotHistoryImportDecision } from '../../snapshot-history/import-service';
import {
  hydratedSectionIsComplete,
  hydratedSectionOpensTrustGates,
  observationCoverageSection,
  observationCoverageState,
} from '../../snapshot-history/coverage-access';
import { hydrateVerifiedCoverageOnEntry } from '../../snapshot-history/trust-hydration';
import type { SnapshotHistoryEnvelope } from '../../snapshot-history/store-types';
import type {
  SnapshotHistoryBase,
  SnapshotHistoryEntry,
  SnapshotItemIdentity,
  SnapshotNestedKind,
  SnapshotObservationItem,
} from '../../snapshot-history/types';
import type { TrackerBase } from '../../village/tracker';
import { createManualLevelDistribution } from '../level-distribution';
import type { ManualBaselineReference, TrackerItemKey, TrackerNestedKind } from '../types';
import { trackerItemKeyStableId } from '../types';
import type { ManualReconciliationError } from '../errors';
import {
  createManualReconciliationEvidence,
  createReconciliationObservation,
  type ManualReconciliationEvidence,
  type ReconciliationObservation,
  type RelatedChangeCoverageState,
  type RelatedChangeEvidence,
} from './evidence';

const HISTOGRAM_SECTIONS = new Set(['buildings', 'buildings2', 'traps', 'traps2']);

export function manualBaselineReferenceForHistoryEntry(
  entry: SnapshotHistoryEntry,
  envelope: SnapshotHistoryEnvelope,
): ManualBaselineReference {
  const duplicateCount = envelope.duplicateMetadata[entry.snapshotID]?.duplicateImportCount ?? 0;
  const revision =
    duplicateCount === 0
      ? entry.snapshotID
      : `${entry.snapshotID}:observation:${String(duplicateCount)}`;
  return {
    revision,
    lineageID: entry.lineageID,
  };
}

export function sourceTimestampMsForImportDecision(
  decision: SnapshotHistoryImportDecision,
): number | null {
  if (!decision.duplicate) {
    return refSecondsToMs(decision.entry.sourceTimestampRefSeconds);
  }
  const meta = decision.envelope.duplicateMetadata[decision.entry.snapshotID];
  return refSecondsToMs(meta?.lastSourceTimestampRefSeconds ?? null);
}

export function buildReconciliationEvidenceFromHistory(input: {
  readonly villageID: UuidString;
  readonly previousEntry: SnapshotHistoryEntry | null;
  readonly decision: SnapshotHistoryImportDecision;
}): ManualReconciliationEvidence {
  const { villageID, previousEntry, decision } = input;
  if (decision.entry.villageID !== villageID) {
    throw { kind: 'villageMismatch' } satisfies ManualReconciliationError;
  }
  if (previousEntry !== null && previousEntry.villageID !== villageID) {
    throw { kind: 'villageMismatch' } satisfies ManualReconciliationError;
  }

  const newBaselineReference = manualBaselineReferenceForHistoryEntry(
    decision.entry,
    decision.envelope,
  );
  const sourceTimestampMs = sourceTimestampMsForImportDecision(decision);
  const previousSourceTimestampMs = refSecondsToMs(
    previousEntry?.sourceTimestampRefSeconds ?? null,
  );

  const historyLineageComparable =
    previousEntry === null ||
    (previousEntry.lineageID === decision.entry.lineageID && decision.lineage.comparisonAllowed);

  const observationsBuilt = observationsInEntry(decision.entry);
  const previousBuilt = previousEntry === null ? null : observationsInEntry(previousEntry);

  const relatedChangesByStableID =
    previousEntry === null ? undefined : relatedChangesFromDiff(previousEntry, decision.entry);

  return createManualReconciliationEvidence({
    villageID,
    newBaselineReference,
    newNormalizedPlayerTag: decision.entry.normalizedPlayerTag,
    sourceTimestampMs,
    duplicate: decision.duplicate,
    lineageComparable: historyLineageComparable,
    observations: observationsBuilt.observations,
    itemKeysByStableID: mergeItemKeys(
      observationsBuilt.itemKeysByStableID,
      previousBuilt?.itemKeysByStableID,
    ),
    previousObservations: previousBuilt?.observations,
    relatedChangesByStableID,
    previousSnapshotID: previousEntry?.snapshotID ?? null,
    previousLineageID: previousEntry?.lineageID ?? null,
    previousSourceTimestampMs,
  });
}

function mergeItemKeys(
  primary: ReadonlyMap<string, TrackerItemKey>,
  secondary: ReadonlyMap<string, TrackerItemKey> | undefined,
): ReadonlyMap<string, TrackerItemKey> {
  if (secondary === undefined || secondary.size === 0) {
    return primary;
  }
  const merged = new Map(primary);
  for (const [stableId, key] of secondary) {
    if (!merged.has(stableId)) {
      merged.set(stableId, key);
    }
  }
  return merged;
}

function observationsInEntry(entry: SnapshotHistoryEntry): {
  readonly observations: ReadonlyMap<string, ReconciliationObservation>;
  readonly itemKeysByStableID: ReadonlyMap<string, TrackerItemKey>;
} {
  const hydrated = hydrateVerifiedCoverageOnEntry({ entry, policy: 'production' });
  const grouped = new Map<string, { key: TrackerItemKey; items: SnapshotObservationItem[] }>();

  for (const item of entry.observation.items) {
    const key = trackerKeyFromIdentity(item.identity);
    if (key === null) {
      continue;
    }
    const stableId = trackerItemKeyStableId(key);
    const existing = grouped.get(stableId);
    if (existing === undefined) {
      grouped.set(stableId, { key, items: [item] });
    } else {
      existing.items.push(item);
    }
  }

  const observations = new Map<string, ReconciliationObservation>();
  const itemKeysByStableID = new Map<string, TrackerItemKey>();

  for (const [stableId, { key, items }] of [...grouped.entries()].sort(([left], [right]) =>
    left.localeCompare(right),
  )) {
    const histogram = isHistogram(key);
    const base = snapshotBase(key.base);
    const requiredFields = ['presence', 'data'] as const;
    const section = observationCoverageSection(hydrated, base, key.rawSection);
    const trustedSectionComplete = section !== undefined && hydratedSectionIsComplete(section);
    const sectionTrustGatesOpen = section !== undefined && hydratedSectionOpensTrustGates(section);
    const coverageComplete = requiredFields.every(
      (field) => observationCoverageState(hydrated, base, key.rawSection, field) === 'complete',
    );
    const safetyFields = ['lvl', 'cnt', ...[...SNAPSHOT_HISTORY_TIMER_FIELDS].sort()];
    const sectionSafetyCoverageComplete = safetyFields.every((field) => {
      const state = observationCoverageState(hydrated, base, key.rawSection, field);
      return state !== undefined && state !== 'partial';
    });
    const timerCoverageComplete = SNAPSHOT_HISTORY_TIMER_FIELDS.every((field) => {
      const state = observationCoverageState(hydrated, base, key.rawSection, field);
      return state === 'complete' || state === 'unavailable';
    });
    const sectionCoverageComplete =
      trustedSectionComplete &&
      coverageComplete &&
      sectionSafetyCoverageComplete &&
      timerCoverageComplete;
    const countCoverageState = observationCoverageState(hydrated, base, key.rawSection, 'cnt');

    const quantities = new Map<number, bigint>();
    let itemLevelCoverageComplete = true;
    let itemCountCoverageComplete = true;

    for (const item of items) {
      if (item.level === undefined || item.level === null || item.level < 0) {
        itemLevelCoverageComplete = false;
        continue;
      }
      let quantity: bigint;
      if (histogram) {
        if (item.count === undefined && Object.keys(item.rawTimerEvidence).length > 0) {
          continue;
        }
        if (item.count === undefined || item.count === null || item.count <= 0) {
          itemCountCoverageComplete = false;
          continue;
        }
        quantity = BigInt(item.count);
      } else {
        if (item.count === undefined && countCoverageState === 'partial') {
          itemCountCoverageComplete = false;
          continue;
        }
        if (item.count !== undefined && item.count !== null && item.count <= 0) {
          itemCountCoverageComplete = false;
          continue;
        }
        quantity = BigInt(Math.max(item.count ?? 1, 1));
      }
      const previous = quantities.get(item.level) ?? 0n;
      const sum = saturatingAdd(previous, quantity);
      if (sum.overflowed || sum.value > INT64_MAX) {
        throw {
          kind: 'invalidObservation',
          message: '项目数量溢出。',
        } satisfies ManualReconciliationError;
      }
      quantities.set(item.level, sum.value);
    }

    const distributionComplete =
      items.length > 0 &&
      itemLevelCoverageComplete &&
      itemCountCoverageComplete &&
      quantities.size > 0;
    const distribution = distributionComplete
      ? createManualLevelDistribution(
          [...quantities.entries()].map(([level, quantity]) => ({ level, quantity })),
        )
      : null;

    const displayName =
      items
        .map((item) => item.display.displayName)
        .find((name) => name !== undefined && name.length > 0) ?? stableId;

    observations.set(
      stableId,
      createReconciliationObservation({
        distribution,
        displayName,
        hasTimer: items.some((item) => Object.keys(item.rawTimerEvidence).length > 0),
        coverageComplete: sectionCoverageComplete,
        distributionComplete,
        sectionTrustGatesOpen,
        timerCoverageComplete,
      }),
    );
    itemKeysByStableID.set(stableId, key);
  }

  return { observations, itemKeysByStableID };
}

function relatedChangesFromDiff(
  previousEntry: SnapshotHistoryEntry,
  nextEntry: SnapshotHistoryEntry,
): ReadonlyMap<string, readonly RelatedChangeEvidence[]> {
  const from = hydrateVerifiedCoverageOnEntry({ entry: previousEntry, policy: 'production' });
  const to = hydrateVerifiedCoverageOnEntry({ entry: nextEntry, policy: 'production' });
  const diff = SnapshotDiffEngine.compare(from, to);
  const byKey = new Map<string, RelatedChangeEvidence[]>();

  for (const change of diff.changes) {
    const key = trackerKeyFromIdentity(change.identity);
    if (key === null) {
      continue;
    }
    const stableId = trackerItemKeyStableId(key);
    const list = byKey.get(stableId) ?? [];
    list.push({ coverageState: mapDiffCoverageState(change) });
    byKey.set(stableId, list);
  }
  return byKey;
}

function mapDiffCoverageState(change: SnapshotChange): RelatedChangeCoverageState {
  switch (change.coverage.state) {
    case 'complete':
      return 'complete';
    case 'partial':
      return 'partial';
    case 'insufficient':
      return 'unavailable';
  }
}

export function trackerKeyFromIdentity(identity: SnapshotItemIdentity): TrackerItemKey | null {
  const base = trackerBase(identity.base);
  if (base === null || identity.rawSection.length === 0 || identity.dataID <= 0n) {
    return null;
  }
  switch (identity.nestedKind) {
    case 'root':
      return {
        base,
        rawSection: identity.rawSection,
        dataID: identity.dataID,
        nestedKind: 'root',
        nestedRootIdentity: null,
        nestedPath: [],
      };
    case 'type':
    case 'module': {
      if (identity.nestedRootDataID === null || identity.nestedRootDataID <= 0n) {
        return null;
      }
      const parent = identity.nestedParentPath.slice(1).flatMap((component) => {
        const kind = trackerNestedKind(component.kind);
        if (kind === null || component.dataID <= 0n) {
          return [];
        }
        return [{ kind, dataID: component.dataID }];
      });
      if (parent.length !== Math.max(identity.nestedParentPath.length - 1, 0)) {
        return null;
      }
      const currentKind = trackerNestedKind(identity.nestedKind);
      if (currentKind === null) {
        return null;
      }
      return {
        base,
        rawSection: identity.rawSection,
        dataID: identity.dataID,
        nestedKind: currentKind,
        nestedRootIdentity: {
          base,
          rawSection: identity.rawSection,
          dataID: identity.nestedRootDataID,
        },
        nestedPath: [...parent, { kind: currentKind, dataID: identity.dataID }],
      };
    }
    case 'unknown':
      return null;
  }
}

function isHistogram(key: TrackerItemKey): boolean {
  return key.nestedKind === 'root' && HISTOGRAM_SECTIONS.has(key.rawSection);
}

function trackerBase(base: SnapshotHistoryBase): TrackerBase | null {
  switch (base) {
    case 'home':
      return 'home';
    case 'builder':
      return 'builder';
    case 'unknown':
      return null;
  }
}

function snapshotBase(base: TrackerBase): SnapshotHistoryBase {
  return base;
}

function trackerNestedKind(kind: SnapshotNestedKind): TrackerNestedKind | null {
  switch (kind) {
    case 'root':
      return 'root';
    case 'type':
      return 'type';
    case 'module':
      return 'module';
    case 'unknown':
      return null;
  }
}

function refSecondsToMs(refSeconds: number | null | undefined): number | null {
  if (refSeconds === null || refSeconds === undefined) {
    return null;
  }
  if (!Number.isFinite(refSeconds)) {
    return Number.NaN;
  }
  return refSecondsToUnixSeconds(refSeconds) * 1000;
}

/** Swift preview：history lineageComparable ∧ (manual baseline 同 lineage 或无 baseline)。 */
export function applyManualLineageComparable(
  evidence: ManualReconciliationEvidence,
  currentBaseline: ManualBaselineReference | null,
): ManualReconciliationEvidence {
  const manualLineageComparable =
    currentBaseline === null ||
    currentBaseline.lineageID === evidence.newBaselineReference.lineageID;
  const lineageComparable = evidence.lineageComparable && manualLineageComparable;
  if (lineageComparable === evidence.lineageComparable) {
    return evidence;
  }
  return { ...evidence, lineageComparable };
}
