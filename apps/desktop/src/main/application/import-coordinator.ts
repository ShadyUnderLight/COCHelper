import type { AccountSnapshot, AccountSnapshotImportError } from '@coc-helper/domain';
import {
  applySnapshotToVillage,
  createVillageProfile,
  parsePendingImport,
  prepareQuickImport,
  type PendingImportPreview,
  type QuickImportPreview,
  type VillageProfile,
} from '@coc-helper/domain';
import type { Clock } from '@coc-helper/domain';
import { generateUuid } from '@coc-helper/wire';

export type VillageStorePort = {
  listVillages(): readonly VillageProfile[];
  saveVillages(villages: readonly VillageProfile[]): void;
  getSelectedVillageId(): string | null;
  setSelectedVillageId(id: string | null): void;
};

export type ImportCoordinatorState = {
  readonly pending: PendingImportPreview | null;
  readonly importText: string;
  readonly importIntoCurrentVillage: boolean;
  readonly lastError: string | null;
};

export class ImportCoordinator {
  private pending: PendingImportPreview | null = null;
  private importText = '';
  private importIntoCurrentVillage = false;
  private lastError: string | null = null;

  constructor(
    private readonly store: VillageStorePort,
    private readonly clock: Clock,
  ) {}

  getState(): ImportCoordinatorState {
    return {
      pending: this.pending,
      importText: this.importText,
      importIntoCurrentVillage: this.importIntoCurrentVillage,
      lastError: this.lastError,
    };
  }

  setImportText(text: string): void {
    this.importText = text;
    this.lastError = null;
  }

  setImportIntoCurrentVillage(value: boolean): void {
    this.importIntoCurrentVillage = value;
  }

  parse(): void {
    this.pending = null;
    this.lastError = null;
    const result = parsePendingImport({
      text: this.importText,
      villages: this.store.listVillages(),
      selectedVillageId: this.store.getSelectedVillageId(),
      importIntoCurrentVillage: this.importIntoCurrentVillage,
      clock: this.clock,
    });
    if (!result.ok) {
      if ('kind' in result.error && result.error.kind === 'ambiguous') {
        this.lastError = result.error.message;
        return;
      }
      this.lastError = formatImportError(result.error);
      return;
    }
    this.pending = result.value;
  }

  discardPending(): void {
    this.pending = null;
    this.lastError = null;
  }

  confirmPending(): boolean {
    const pending = this.pending;
    if (pending === null) {
      return false;
    }

    const villages = [...this.store.listVillages()];
    switch (pending.target.kind) {
      case 'create': {
        const snapshot = pending.snapshot;
        const village = createVillageProfile({
          id: generateUuid(),
          name: snapshot.tag?.trim() || `村庄 ${villages.length + 1}`,
          accountSnapshot: snapshot,
        });
        villages.push(village);
        this.store.saveVillages(villages);
        this.store.setSelectedVillageId(village.id);
        break;
      }
      case 'existing': {
        const index = pending.target.index;
        if (index < 0 || index >= villages.length) {
          return false;
        }
        villages[index] = applySnapshotToVillage(villages[index]!, pending.snapshot);
        this.store.saveVillages(villages);
        this.store.setSelectedVillageId(villages[index]!.id);
        break;
      }
      case 'ambiguous':
        return false;
    }

    this.pending = null;
    this.importText = pending.snapshot.originalText;
    this.lastError = null;
    return true;
  }

  prepareQuickImport(text: string, targetVillageId: string):
    | { readonly ok: true; readonly value: QuickImportPreview }
    | { readonly ok: false; readonly error: string } {
    const result = prepareQuickImport({
      text,
      targetVillageId,
      villages: this.store.listVillages(),
      clock: this.clock,
    });
    if (!result.ok) {
      return { ok: false, error: formatQuickImportError(result.error) };
    }
    return result;
  }

  applyQuickImport(preview: QuickImportPreview): boolean {
    const villages = [...this.store.listVillages()];
    const index = villages.findIndex((village) => village.id === preview.targetVillageId);
    if (index < 0) {
      this.lastError = '目标村庄不存在，无法导入。';
      return false;
    }
    villages[index] = applySnapshotToVillage(villages[index]!, preview.snapshot);
    this.store.saveVillages(villages);
    this.store.setSelectedVillageId(preview.targetVillageId);
    this.pending = null;
    this.importText = preview.snapshot.originalText;
    this.lastError = null;
    return true;
  }
}

export class InMemoryVillageStore implements VillageStorePort {
  private villages: VillageProfile[] = [];
  private selectedVillageId: string | null = null;

  listVillages(): readonly VillageProfile[] {
    return this.villages;
  }

  saveVillages(villages: readonly VillageProfile[]): void {
    this.villages = [...villages];
  }

  getSelectedVillageId(): string | null {
    return this.selectedVillageId;
  }

  setSelectedVillageId(id: string | null): void {
    this.selectedVillageId = id;
  }

  seed(villages: readonly VillageProfile[], selectedVillageId: string | null = null): void {
    this.villages = [...villages];
    this.selectedVillageId = selectedVillageId;
  }
}

function formatImportError(error: AccountSnapshotImportError | { readonly kind: 'ambiguous'; readonly message: string }): string {
  if ('kind' in error && error.kind === 'ambiguous') {
    return error.message;
  }
  switch (error.kind) {
    case 'emptyInput':
      return '没有可解析的文本。请先从游戏复制并粘贴 JSON。';
    case 'topLevelMustBeObject':
      return 'JSON 顶层必须是对象，以 { 开头。';
    case 'invalidJSON':
      return `JSON 解析失败：${error.message}`;
  }
}

function formatQuickImportError(
  error: import('@coc-helper/domain').QuickImportError,
): string {
  switch (error.kind) {
    case 'emptyClipboard':
      return '系统剪贴板中没有可用的文本。';
    case 'parseFailed':
      return formatImportError(error.error);
    case 'targetVillageMissing':
      return '目标村庄不存在，无法导入。';
    case 'tagBelongsToAnotherVillage':
      return `账号 Tag（${error.tag}）属于「${error.villageName}」，不能导入到当前村庄。`;
  }
}

export type { AccountSnapshot };
