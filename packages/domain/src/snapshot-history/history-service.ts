import type { UuidString } from '@coc-helper/wire';
import { parseUuid, unixSecondsToRefSeconds } from '@coc-helper/wire';

import type { AccountSnapshot } from '../account/types';
import type { CraftTableCatalog } from '../catalog/craft-table';
import type { GameCatalog } from '../catalog/game-catalog';
import type { VillageProfile } from '../import/types';
import { canonicalizeSnapshotHistoryWithLineage } from './canonicalizer';
import type { SnapshotHistoryStoreError } from './errors';
import { appendSnapshotHistoryEntry } from './envelope-mutation';
import { createSnapshotHistoryMigrationMarker } from './envelope-wire';
import { validateSnapshotHistoryEnvelope } from './envelope-validate';
import { planSnapshotHistoryImport, type SnapshotHistoryImportDecision } from './import-service';
import { resolveSnapshotLineage } from './lineage-resolver';
import { SNAPSHOT_HISTORY_SCHEMA } from './schema';
import { envelopeIsMigrated, createSnapshotHistoryEnvelope } from './store-types';
import type { SnapshotHistoryEnvelope } from './store-types';
import type { SnapshotHistoryStore } from './store-port';
import type { SnapshotCoverageProof, SnapshotCoverageSourceUniverse } from './types';

export type SnapshotHistoryService = {
  readonly store: SnapshotHistoryStore;
  loadOrMigrate(input: LoadOrMigrateSnapshotHistoryInput): SnapshotHistoryEnvelope;
  planImport(input: PlanSnapshotHistoryImportForServiceInput): SnapshotHistoryImportDecision;
};

export type LoadOrMigrateSnapshotHistoryInput = {
  readonly villages: readonly VillageProfile[];
  readonly nowRefSeconds?: number;
  readonly catalog?: GameCatalog;
  readonly craftTableCatalog?: CraftTableCatalog;
  readonly sectionProofs?: Readonly<
    Record<string, Readonly<Record<string, SnapshotCoverageProof>>>
  >;
  readonly sourceUniverses?: Readonly<Record<string, SnapshotCoverageSourceUniverse>>;
};

export type PlanSnapshotHistoryImportForServiceInput = {
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

export function envelopeHasPersistedHistory(envelope: SnapshotHistoryEnvelope): boolean {
  return (
    envelope.entries.length > 0 ||
    envelope.lineages.length > 0 ||
    Object.keys(envelope.duplicateMetadata).length > 0
  );
}

export function upgradeExistingSnapshotHistoryEnvelope(
  existing: SnapshotHistoryEnvelope,
  nowRefSeconds: number,
): SnapshotHistoryEnvelope {
  if (
    existing.migrationMarker !== null &&
    existing.migrationMarker.version !== SNAPSHOT_HISTORY_SCHEMA.envelope
  ) {
    throw storeError({
      kind: 'unsupportedSchema',
      version: existing.migrationMarker.version,
    });
  }
  if (!envelopeHasPersistedHistory(existing)) {
    throw storeError({
      kind: 'invalidEntry',
      message: '空 envelope 不得走 preserving upgrade；应改用 villages 迁移。',
    });
  }
  return validateSnapshotHistoryEnvelope({
    ...existing,
    migrationMarker: createSnapshotHistoryMigrationMarker(nowRefSeconds),
    lastDiagnostic: null,
  });
}

export function migrateSnapshotHistoryFromVillages(
  input: LoadOrMigrateSnapshotHistoryInput,
  nowRefSeconds: number,
): SnapshotHistoryEnvelope {
  let envelope = createSnapshotHistoryEnvelope({});
  for (const village of input.villages) {
    if (village.accountSnapshot === null) {
      continue;
    }
    const villageID = parseUuid(village.id);
    if (villageID === undefined) {
      continue;
    }
    const lineage = resolveSnapshotLineage({
      villageID,
      normalizedPlayerTag: village.accountSnapshot.tag,
      previous: null,
    });
    const entry = canonicalizeSnapshotHistoryWithLineage(village.accountSnapshot, {
      villageID,
      lineage,
      appliedAtRefSeconds: nowRefSeconds,
      catalog: input.catalog,
      craftTableCatalog: input.craftTableCatalog,
      sectionProofs: input.sectionProofs?.[village.id] ?? {},
      sourceUniverse: input.sourceUniverses?.[village.id],
    });
    envelope = appendSnapshotHistoryEntry(envelope, entry, lineage);
  }

  return validateSnapshotHistoryEnvelope({
    ...envelope,
    migrationMarker: createSnapshotHistoryMigrationMarker(nowRefSeconds),
    lastDiagnostic: null,
  });
}

export function createSnapshotHistoryService(store: SnapshotHistoryStore): SnapshotHistoryService {
  return {
    store,
    loadOrMigrate(input) {
      const nowRefSeconds = input.nowRefSeconds ?? unixSecondsToRefSeconds(Date.now() / 1000);
      const existing = store.load();

      if (existing !== null) {
        if (envelopeIsMigrated(existing)) {
          return existing;
        }

        if (envelopeHasPersistedHistory(existing)) {
          const upgraded = upgradeExistingSnapshotHistoryEnvelope(existing, nowRefSeconds);
          store.save(upgraded);
          return upgraded;
        }

        // 空壳 pre-migration envelope：仅此时才允许从 villages 种子化。
      }

      const migrated = migrateSnapshotHistoryFromVillages(input, nowRefSeconds);
      store.save(migrated);
      return migrated;
    },
    planImport(planInput) {
      return planSnapshotHistoryImport(planInput);
    },
  };
}

function storeError(error: SnapshotHistoryStoreError): SnapshotHistoryStoreError {
  return error;
}
