/**
 * SnapshotImportService：显式目标的 prepare/commit（#276）。
 * prepare 绝不读取权威 selectedVillageId；仅使用请求中的 villageId。
 * commit/discard 必须携带 expectedGeneration（CAS）。
 */

import type {
  ImportCommitPayload,
  ImportDiscardPayload,
  ImportPreparePayload,
  ImportPrepareRequest,
} from '@coc-helper/contracts';
import {
  applySnapshotToVillage,
  createVillageProfile,
  parsePendingImport,
  type Clock,
  type PendingImportPreview,
  type VillageProfile,
} from '@coc-helper/domain';
import { generateUuid } from '@coc-helper/wire';

import { AppServiceError, type AppAuthoritativeState } from './app-authoritative-state';
import { toPendingImportPreviewWire, toPendingImportSummaryDto } from './dto-mappers';

export class SnapshotImportService {
  constructor(
    private readonly state: AppAuthoritativeState,
    private readonly clock: Clock,
  ) {}

  prepare(request: ImportPrepareRequest): ImportPreparePayload {
    if (!this.state.canWrite()) {
      throw new AppServiceError('unavailable', '当前处于恢复或只读状态，无法导入。');
    }
    const villages = this.state.listVillages();
    /** 显式目标：只用请求 villageId，不读 store selected。 */
    const explicitVillageId = request.villageId ?? null;
    if (explicitVillageId !== null) {
      const exists = villages.some((village) => village.id === explicitVillageId);
      if (!exists) {
        throw new AppServiceError('notFound', '目标村庄不存在，无法导入。');
      }
    }

    const result = parsePendingImport({
      text: request.text,
      villages,
      selectedVillageId: explicitVillageId,
      importIntoCurrentVillage: explicitVillageId !== null,
      clock: this.clock,
    });
    if (!result.ok) {
      if ('kind' in result.error && result.error.kind === 'ambiguous') {
        throw new AppServiceError('conflict', result.error.message);
      }
      throw new AppServiceError('validation', formatImportError(result.error));
    }

    const pending = result.value;
    /** 必须先完成 DTO 转换；失败时不得 setPending / bump generation。 */
    const summary = mapPendingDtos(pending, villages);
    this.state.setPending(pending);
    return {
      generation: this.state.getGeneration(),
      pending: summary.pending,
      preview: summary.preview,
    };
  }

  commit(expectedGeneration: number): ImportCommitPayload {
    if (!this.state.canWrite()) {
      throw new AppServiceError('unavailable', '当前处于恢复或只读状态，无法导入。');
    }
    assertExpectedGeneration(this.state.getGeneration(), expectedGeneration);
    const pending = this.state.getPending();
    if (pending === null) {
      throw new AppServiceError('validation', '没有待确认的导入。');
    }

    const store = this.state.getVillageStore();
    const villages = [...store.listVillages()];
    applyPendingToVillages(pending, villages, store);

    /** 村庄主数据已提交：无论 selection soft-fail，都必须清 pending 并 bump。 */
    this.state.setPending(null, { bump: false });
    this.state.notifyMutation();
    return {
      generation: this.state.getGeneration(),
      selectedVillageId: store.getSelectedVillageId(),
    };
  }

  discard(expectedGeneration: number): ImportDiscardPayload {
    assertExpectedGeneration(this.state.getGeneration(), expectedGeneration);
    if (this.state.getPending() === null) {
      return { generation: this.state.getGeneration() };
    }
    this.state.setPending(null);
    return { generation: this.state.getGeneration() };
  }
}

function assertExpectedGeneration(current: number, expected: number): void {
  if (current !== expected) {
    throw new AppServiceError('conflict', '导入状态已过期，请刷新后重试。');
  }
}

function mapPendingDtos(
  pending: PendingImportPreview,
  villages: readonly VillageProfile[],
): Pick<ImportPreparePayload, 'pending' | 'preview'> {
  try {
    return {
      pending: toPendingImportSummaryDto(pending, villages),
      preview: toPendingImportPreviewWire(pending),
    };
  } catch (error) {
    if (error instanceof RangeError) {
      throw new AppServiceError('validation', '导入预览包含无法经 IPC 传递的数值。');
    }
    throw error;
  }
}

function applyPendingToVillages(
  pending: PendingImportPreview,
  villages: VillageProfile[],
  store: {
    saveVillages(villages: readonly VillageProfile[]): void;
    setSelectedVillageId(id: string | null): void;
  },
): void {
  const target = pending.target;
  switch (target.kind) {
    case 'create': {
      const snapshot = pending.snapshot;
      const village = createVillageProfile({
        id: generateUuid(),
        name: snapshot.tag?.trim() || `村庄 ${villages.length + 1}`,
        accountSnapshot: snapshot,
      });
      villages.push(village);
      store.saveVillages(villages);
      store.setSelectedVillageId(village.id);
      return;
    }
    case 'existing': {
      const index = villages.findIndex((village) => village.id === target.villageId);
      if (index < 0) {
        throw new AppServiceError('notFound', '目标村庄不存在，无法导入。');
      }
      villages[index] = applySnapshotToVillage(villages[index]!, pending.snapshot);
      store.saveVillages(villages);
      store.setSelectedVillageId(target.villageId);
      return;
    }
    case 'ambiguous':
      throw new AppServiceError('conflict', '导入目标不明确。');
  }
}

function formatImportError(error: import('@coc-helper/domain').AccountSnapshotImportError): string {
  switch (error.kind) {
    case 'emptyInput':
      return '没有可解析的文本。请先从游戏复制并粘贴 JSON。';
    case 'topLevelMustBeObject':
      return 'JSON 顶层必须是对象，以 { 开头。';
    case 'invalidJSON':
      return `JSON 解析失败：${error.message}`;
  }
}
