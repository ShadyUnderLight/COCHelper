/**
 * Domain → IPC DTO 映射。只产出 JSON-serializable 纯数据，不含 class / Buffer / Token。
 */

import type {
  AccountItemWire,
  AccountSnapshotWire,
  PendingImportPreviewWire,
  PendingImportSummaryDto,
  VillageSummaryDto,
} from '@coc-helper/contracts';
import type {
  AccountItem,
  AccountSnapshot,
  PendingImportPreview,
  VillageProfile,
} from '@coc-helper/domain';
import { unixSecondsToRefSeconds } from '@coc-helper/wire';

export function toVillageSummaryDto(village: VillageProfile): VillageSummaryDto {
  return {
    id: village.id,
    name: village.name,
    tag: village.tag,
    hasImportedData: village.hasImportedData,
  };
}

export function toPendingImportSummaryDto(
  pending: PendingImportPreview,
  villages: readonly VillageProfile[],
): PendingImportSummaryDto {
  const target = pending.target;
  switch (target.kind) {
    case 'existing': {
      const village = villages.find((entry) => entry.id === target.villageId);
      return {
        targetKind: 'existing',
        targetVillageId: target.villageId,
        ...(village !== undefined ? { targetVillageName: village.name } : {}),
        snapshotTag: pending.snapshot.tag,
      };
    }
    case 'create':
      return {
        targetKind: 'create',
        snapshotTag: pending.snapshot.tag,
      };
    case 'ambiguous':
      throw new Error('ambiguous pending 不得进入 IPC summary');
  }
}

export function toPendingImportPreviewWire(
  pending: PendingImportPreview,
): PendingImportPreviewWire {
  const snapshot = toAccountSnapshotWire(pending.snapshot);
  const target = pending.target;
  switch (target.kind) {
    case 'existing':
      return {
        snapshot,
        targetKind: 'existing',
        targetVillageId: target.villageId,
      };
    case 'create':
      return {
        snapshot,
        targetKind: 'create',
      };
    case 'ambiguous':
      return {
        snapshot,
        targetKind: 'ambiguous',
        ambiguousTag: target.tag,
        ambiguousVillageNames: target.villageNames,
      };
  }
}

export function toAccountSnapshotWire(snapshot: AccountSnapshot): AccountSnapshotWire {
  const wire: AccountSnapshotWire = {
    importedAt: unixSecondsToRefSeconds(snapshot.importedAtMs / 1000),
    originalText: snapshot.originalText,
    objectSections: mapObjectSections(snapshot.objectSections),
    numericSections: mapNumericSections(snapshot.numericSections),
    boosts: mapBoosts(snapshot.boosts),
    unknownTopLevelKeys: [...snapshot.unknownTopLevelKeys],
    diagnostics: snapshot.diagnostics.map((diagnostic) => ({
      id: diagnostic.id,
      severity: diagnostic.severity,
      path: diagnostic.path,
      message: diagnostic.message,
    })),
  };
  return {
    ...wire,
    ...(snapshot.tag !== null ? { tag: snapshot.tag } : {}),
    ...(snapshot.capturedAtMs !== null
      ? { capturedAt: unixSecondsToRefSeconds(snapshot.capturedAtMs / 1000) }
      : {}),
    ...(snapshot.ageSeconds !== null ? { ageSeconds: bigintToNumber(snapshot.ageSeconds) } : {}),
  };
}

function mapObjectSections(
  sections: Readonly<Record<string, readonly AccountItem[]>>,
): Readonly<Record<string, readonly AccountItemWire[]>> {
  const result: Record<string, AccountItemWire[]> = {};
  for (const [key, items] of Object.entries(sections)) {
    result[key] = items.map(toAccountItemWire);
  }
  return result;
}

function mapNumericSections(
  sections: Readonly<Record<string, readonly bigint[]>>,
): Readonly<Record<string, readonly number[]>> {
  const result: Record<string, number[]> = {};
  for (const [key, values] of Object.entries(sections)) {
    result[key] = values.map(bigintToNumber);
  }
  return result;
}

function mapBoosts(boosts: Readonly<Record<string, bigint>>): Readonly<Record<string, number>> {
  const result: Record<string, number> = {};
  for (const [key, value] of Object.entries(boosts)) {
    result[key] = bigintToNumber(value);
  }
  return result;
}

function toAccountItemWire(item: AccountItem): AccountItemWire {
  return {
    id: item.id,
    section: item.section,
    dataID: bigintToNumber(item.dataID),
    ...(item.level !== null ? { level: item.level } : {}),
    ...(item.count !== null ? { count: item.count } : {}),
    ...(item.timerSeconds !== null ? { timerSeconds: bigintToNumber(item.timerSeconds) } : {}),
    ...(item.remainingSeconds !== null
      ? { remainingSeconds: bigintToNumber(item.remainingSeconds) }
      : {}),
    ...(item.helperTimerSeconds !== null
      ? { helperTimerSeconds: bigintToNumber(item.helperTimerSeconds) }
      : {}),
    ...(item.remainingHelperSeconds !== null
      ? { remainingHelperSeconds: bigintToNumber(item.remainingHelperSeconds) }
      : {}),
    ...(item.helperCooldownSeconds !== null
      ? { helperCooldownSeconds: bigintToNumber(item.helperCooldownSeconds) }
      : {}),
    ...(item.remainingHelperCooldownSeconds !== null
      ? { remainingHelperCooldownSeconds: bigintToNumber(item.remainingHelperCooldownSeconds) }
      : {}),
    helperRecurrent: item.helperRecurrent,
    ...(item.gearUp !== null ? { gearUp: item.gearUp } : {}),
    ...(item.weapon !== null ? { weapon: item.weapon } : {}),
    types: item.types.map(toAccountItemWire),
    modules: item.modules.map(toAccountItemWire),
  };
}

function bigintToNumber(value: bigint): number {
  const asNumber = Number(value);
  if (!Number.isSafeInteger(asNumber) || BigInt(asNumber) !== value) {
    throw new RangeError(`IPC DTO 超出 JS safe integer：${value.toString()}`);
  }
  return asNumber;
}
