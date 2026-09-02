import type { UuidString } from '@coc-helper/wire';
import { unixSecondsToRefSeconds } from '@coc-helper/wire';

import type { AccountSnapshot } from '../account/types';
import type { CraftTableCatalog } from '../catalog/craft-table';
import type { GameCatalog } from '../catalog/game-catalog';
import { normalizedTag } from '../tag/validator';
import { canonicalizeSnapshotHistoryWithLineage } from './canonicalizer';
import { snapshotHistoryDuplicateKeysMatch } from './duplicate-key';
import type { SnapshotHistoryServiceError } from './errors';
import { appendSnapshotHistoryEntry } from './envelope-mutation';
import { resolveSnapshotLineage } from './lineage-resolver';
import { envelopeIsMigrated, envelopeActiveLineage } from './store-types';
import type { SnapshotHistoryDuplicateMetadata, SnapshotHistoryEnvelope } from './store-types';
import type {
  SnapshotCoverageSourceUniverse,
  SnapshotHistoryEntry,
  SnapshotLineageResolution,
  SnapshotCoverageProof,
} from './types';

export type SnapshotHistoryImportDecision = {
  readonly envelope: SnapshotHistoryEnvelope;
  readonly entry: SnapshotHistoryEntry;
  readonly lineage: SnapshotLineageResolution;
  readonly appended: boolean;
  readonly duplicate: boolean;
};

export type PlanSnapshotHistoryImportInput = {
  readonly snapshot: AccountSnapshot;
  readonly villageID: UuidString;
  readonly currentTag: string | null | undefined;
  readonly hasCurrentSnapshot: boolean;
  readonly envelope: SnapshotHistoryEnvelope;
  readonly appliedAtRefSeconds?: number;
  readonly catalog?: GameCatalog;
  readonly craftTableCatalog?: CraftTableCatalog;
  readonly sectionProofs?: Readonly<Record<string, SnapshotCoverageProof>>;
  readonly sourceUniverse?: SnapshotCoverageSourceUniverse | null;
};

function serviceError(error: SnapshotHistoryServiceError): SnapshotHistoryServiceError {
  return error;
}

export function planSnapshotHistoryImport(
  input: PlanSnapshotHistoryImportInput,
): SnapshotHistoryImportDecision {
  if (!envelopeIsMigrated(input.envelope)) {
    throw serviceError({
      kind: 'historyUnavailable',
      message: '历史尚未完成迁移。',
    });
  }

  const active = envelopeActiveLineage(input.envelope, input.villageID);
  if (
    input.hasCurrentSnapshot &&
    active !== undefined &&
    normalizedTag(input.currentTag) !== active.normalizedPlayerTag
  ) {
    throw serviceError({
      kind: 'lineageConflict',
      message: '当前村庄 Tag 与历史 active lineage 不一致。',
    });
  }

  const previous =
    active === undefined
      ? null
      : {
          villageID: active.villageID,
          lineageID: active.lineageID,
          normalizedPlayerTag: active.normalizedPlayerTag,
          hasConflict: active.hasConflict,
        };

  const lineage = resolveSnapshotLineage({
    villageID: input.villageID,
    normalizedPlayerTag: input.snapshot.tag,
    previous,
  });

  const appliedAtRefSeconds =
    input.appliedAtRefSeconds ?? unixSecondsToRefSeconds(Date.now() / 1000);

  const candidate = canonicalizeSnapshotHistoryWithLineage(input.snapshot, {
    villageID: input.villageID,
    lineage,
    appliedAtRefSeconds,
    catalog: input.catalog,
    craftTableCatalog: input.craftTableCatalog,
    sectionProofs: input.sectionProofs,
    sourceUniverse: input.sourceUniverse,
  });

  let updated: SnapshotHistoryEnvelope = {
    ...input.envelope,
    duplicateMetadata: { ...input.envelope.duplicateMetadata },
  };

  if (lineage.outcome === 'continued' && active !== undefined) {
    const previousEntry = input.envelope.entries.find(
      (entry) => entry.snapshotID === active.lastEntryID,
    );
    if (
      previousEntry !== undefined &&
      snapshotHistoryDuplicateKeysMatch(previousEntry, candidate)
    ) {
      const key = previousEntry.snapshotID;
      const previousMetadata = updated.duplicateMetadata[key];
      const duplicateMetadata: SnapshotHistoryDuplicateMetadata = {
        lastSeenAtRefSeconds: appliedAtRefSeconds,
        lastSourceTimestampRefSeconds:
          input.snapshot.capturedAtMs === null
            ? null
            : unixSecondsToRefSeconds(input.snapshot.capturedAtMs / 1000),
        duplicateImportCount: (previousMetadata?.duplicateImportCount ?? 0) + 1,
      };
      updated = {
        ...updated,
        duplicateMetadata: {
          ...updated.duplicateMetadata,
          [key]: duplicateMetadata,
        },
        lastDiagnostic: null,
      };
      return {
        envelope: updated,
        entry: previousEntry,
        lineage,
        appended: false,
        duplicate: true,
      };
    }
  }

  updated = appendSnapshotHistoryEntry(updated, candidate, lineage);

  return {
    envelope: updated,
    entry: candidate,
    lineage,
    appended: true,
    duplicate: false,
  };
}
