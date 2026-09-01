import {
  parseAccountSnapshot,
  type AccountSnapshot,
  type AccountSnapshotImportError,
} from '../account';
import type { Clock } from '../primitives';
import { interceptKey, normalizedTag } from '../tag/validator';
import type {
  PendingImportPreview,
  PendingSnapshotTarget,
  QuickImportError,
  QuickImportPreview,
  VillageProfile,
} from './types';

export function applySnapshotToVillage(
  village: VillageProfile,
  snapshot: AccountSnapshot,
): VillageProfile {
  const previousTag = normalizedTag(village.tag);
  const nextTag = normalizedTag(snapshot.tag);
  const tagChanged = previousTag !== nextTag;
  return {
    ...village,
    tag: snapshot.tag,
    accountSnapshot: snapshot,
    officialAPIState: tagChanged ? null : village.officialAPIState,
    hasImportedData: true,
  };
}

export function resolvePendingTarget(
  snapshot: AccountSnapshot,
  villages: readonly VillageProfile[],
  options: {
    readonly selectedVillageId: string | null;
    readonly importIntoCurrentVillage: boolean;
  },
): PendingSnapshotTarget {
  const snapshotTag = normalizedTag(snapshot.tag);
  if (snapshotTag !== undefined) {
    const matchingIndices = villages
      .map((village, index) => ({ village, index }))
      .filter(({ village }) => normalizedTag(village.tag) === snapshotTag)
      .map(({ index }) => index);
    if (matchingIndices.length > 1) {
      return {
        kind: 'ambiguous',
        tag: snapshotTag,
        villageNames: matchingIndices.map((index) => villages[index]!.name),
      };
    }
    if (matchingIndices.length === 1) {
      return { kind: 'existing', villageId: villages[matchingIndices[0]!]!.id };
    }
  }

  const currentIndex =
    options.selectedVillageId === null
      ? -1
      : villages.findIndex((village) => village.id === options.selectedVillageId);
  if (
    currentIndex >= 0 &&
    (options.importIntoCurrentVillage ||
      (villages.length === 1 && !villages[currentIndex]!.hasImportedData))
  ) {
    return { kind: 'existing', villageId: villages[currentIndex]!.id };
  }
  return { kind: 'create' };
}

export function ambiguousImportTargetMessage(tag: string, villageNames: readonly string[]): string {
  return (
    `账号 Tag（${tag}）对应多个村庄档案：${villageNames.join('、')}` +
    '。为避免绑定错误，导入已拒绝，请先保留唯一匹配档案后重试。'
  );
}

export function prepareQuickImport(input: {
  readonly text: string;
  readonly targetVillageId: string;
  readonly villages: readonly VillageProfile[];
  readonly clock: Clock;
}):
  | { readonly ok: true; readonly value: QuickImportPreview }
  | { readonly ok: false; readonly error: QuickImportError } {
  if (input.text.trim().length === 0) {
    return { ok: false, error: { kind: 'emptyClipboard' } };
  }

  const parsed = parseAccountSnapshot(input.text, { clock: input.clock });
  if (!parsed.ok) {
    return { ok: false, error: { kind: 'parseFailed', error: parsed.error } };
  }

  const target = input.villages.find((village) => village.id === input.targetVillageId);
  if (target === undefined) {
    return { ok: false, error: { kind: 'targetVillageMissing' } };
  }

  const snapshotKey = interceptKey(parsed.value.tag);
  if (snapshotKey !== undefined) {
    const other = input.villages.find(
      (village) =>
        village.id !== input.targetVillageId && interceptKey(village.tag) === snapshotKey,
    );
    if (other !== undefined) {
      return {
        ok: false,
        error: {
          kind: 'tagBelongsToAnotherVillage',
          tag: parsed.value.tag ?? '',
          villageName: other.name,
        },
      };
    }
  }

  const normalizedSnapshotTag = normalizedTag(parsed.value.tag);
  const replacesSameTag =
    normalizedSnapshotTag !== undefined && normalizedSnapshotTag === normalizedTag(target.tag);
  const targetVillageHasSnapshot = target.hasImportedData;

  let destinationDescription: string;
  if (!targetVillageHasSnapshot) {
    destinationDescription = `将建立「${target.name}」的账号快照并导入`;
  } else if (normalizedSnapshotTag === undefined) {
    destinationDescription = `导入目标：按当前详情页应用到「${target.name}」。JSON 未提供账号 Tag，将按当前目标处理，原官方数据将因 Tag 缺失被重置`;
  } else if (replacesSameTag) {
    destinationDescription = `导入目标：按当前详情页更新「${target.name}」`;
  } else {
    destinationDescription = `导入目标：按当前详情页应用到「${target.name}」，原官方数据将因 Tag 变化被重置`;
  }

  return {
    ok: true,
    value: {
      snapshot: parsed.value,
      targetVillageId: target.id,
      targetVillageName: target.name,
      targetVillageTag: target.tag,
      targetVillageHasSnapshot,
      replacesSameTag,
      destinationDescription,
    },
  };
}

export function parsePendingImport(input: {
  readonly text: string;
  readonly villages: readonly VillageProfile[];
  readonly selectedVillageId: string | null;
  readonly importIntoCurrentVillage: boolean;
  readonly clock: Clock;
}):
  | { readonly ok: true; readonly value: PendingImportPreview }
  | {
      readonly ok: false;
      readonly error:
        AccountSnapshotImportError | { readonly kind: 'ambiguous'; readonly message: string };
    } {
  const parsed = parseAccountSnapshot(input.text, { clock: input.clock });
  if (!parsed.ok) {
    return { ok: false, error: parsed.error };
  }

  const target = resolvePendingTarget(parsed.value, input.villages, {
    selectedVillageId: input.selectedVillageId,
    importIntoCurrentVillage: input.importIntoCurrentVillage,
  });
  if (target.kind === 'ambiguous') {
    return {
      ok: false,
      error: {
        kind: 'ambiguous',
        message: ambiguousImportTargetMessage(target.tag, target.villageNames),
      },
    };
  }

  return {
    ok: true,
    value: {
      snapshot: parsed.value,
      target,
    },
  };
}

export function isReimportingExistingVillage(
  snapshot: AccountSnapshot,
  village: VillageProfile,
): boolean {
  const snapshotTag = normalizedTag(snapshot.tag);
  if (snapshotTag === undefined) {
    return false;
  }
  return normalizedTag(village.tag) === snapshotTag;
}

export function pendingAccountSnapshotActionTitle(
  snapshot: AccountSnapshot,
  villages: readonly VillageProfile[],
  target: PendingSnapshotTarget,
): string | null {
  switch (target.kind) {
    case 'ambiguous':
      return '无法确定导入目标';
    case 'existing': {
      const village = villages.find((entry) => entry.id === target.villageId);
      const targetName = village?.name ?? '未知村庄';
      const action =
        village !== undefined && isReimportingExistingVillage(snapshot, village)
          ? '更新'
          : '应用到';
      return `${action}「${targetName}」`;
    }
    case 'create': {
      const newName = normalizedTag(snapshot.tag) ?? `村庄 ${villages.length + 1}`;
      return `创建「${newName}」并导入`;
    }
  }
}
