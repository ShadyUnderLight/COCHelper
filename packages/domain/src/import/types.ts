import type { AccountSnapshot, AccountSnapshotImportError } from '../account';
import { accountImportErrorMessage } from '../account';

export type VillageProfile = {
  readonly id: string;
  name: string;
  tag: string | null;
  accountSnapshot: AccountSnapshot | null;
  officialAPIState: unknown | null;
  readonly hasImportedData: boolean;
};

export function createVillageProfile(input: {
  readonly id: string;
  name: string;
  accountSnapshot?: AccountSnapshot | null;
  officialAPIState?: unknown | null;
}): VillageProfile {
  const accountSnapshot = input.accountSnapshot ?? null;
  return {
    id: input.id,
    name: input.name.trim().length === 0 ? '未命名村庄' : input.name.trim(),
    tag: accountSnapshot?.tag ?? null,
    accountSnapshot,
    officialAPIState: input.officialAPIState ?? null,
    hasImportedData: accountSnapshot !== null,
  };
}

export type PendingSnapshotTarget =
  | { readonly kind: 'existing'; readonly index: number }
  | { readonly kind: 'create' }
  | { readonly kind: 'ambiguous'; readonly tag: string; readonly villageNames: readonly string[] };

export type QuickImportPreview = {
  readonly snapshot: AccountSnapshot;
  readonly targetVillageId: string;
  readonly targetVillageName: string;
  readonly targetVillageTag: string | null;
  readonly targetVillageHasSnapshot: boolean;
  readonly replacesSameTag: boolean;
  readonly destinationDescription: string;
};

export type QuickImportError =
  | { readonly kind: 'emptyClipboard' }
  | { readonly kind: 'parseFailed'; readonly error: import('../account').AccountSnapshotImportError }
  | { readonly kind: 'targetVillageMissing' }
  | { readonly kind: 'tagBelongsToAnotherVillage'; readonly tag: string; readonly villageName: string };

export function quickImportErrorMessage(error: QuickImportError): string {
  switch (error.kind) {
    case 'emptyClipboard':
      return '系统剪贴板中没有可用的文本。';
    case 'parseFailed':
      return accountImportErrorMessage(error.error);
    case 'targetVillageMissing':
      return '目标村庄不存在，无法导入。';
    case 'tagBelongsToAnotherVillage':
      return `账号 Tag（${error.tag}）属于「${error.villageName}」，不能导入到当前村庄。`;
  }
}

export type PendingImportPreview = {
  readonly snapshot: AccountSnapshot;
  readonly target: PendingSnapshotTarget;
};
