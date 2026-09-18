/**
 * Manual 会话态（#277-F）：纯函数，只消费 Manual IPC DTO。
 */

import type { ManualStatePayload, ManualTrackerStatusDto } from '@coc-helper/contracts';

export type ManualView = {
  readonly status: 'idle' | 'loading' | 'ready' | 'error';
  readonly payload: ManualStatePayload | null;
  readonly lastError: string | null;
};

export const IDLE_MANUAL_VIEW: ManualView = {
  status: 'idle',
  payload: null,
  lastError: null,
};

export function manualStatusLabel(status: ManualTrackerStatusDto): string {
  switch (status) {
    case 'missing':
      return '尚未初始化';
    case 'empty':
      return '暂无手动升级数据';
    case 'unavailable':
      return '不可用';
    case 'migrationRequired':
      return '需要迁移';
    case 'available':
      return '可用';
    default: {
      const exhaustive: never = status;
      throw new Error(`未知 manual 状态：${String(exhaustive)}`);
    }
  }
}

export function isManualQueryStale(view: ManualView): boolean {
  return view.status === 'ready' && view.lastError !== null;
}

export function isManualCommandEnabled(
  payload: ManualStatePayload | null,
  canWrite: boolean,
  queryStale = false,
): boolean {
  return canWrite && !queryStale && payload !== null && payload.status === 'available';
}

export function manualStatusNotice(payload: ManualStatePayload): string | null {
  if (payload.error !== null && payload.error.length > 0) {
    return payload.error;
  }
  switch (payload.status) {
    case 'missing':
      return '手动升级存储尚未初始化，导入快照后可开始使用。';
    case 'empty':
      return '该村庄尚无手动升级基线，请先导入账号快照。';
    case 'unavailable':
      return payload.error ?? '手动升级存储不可用。';
    case 'migrationRequired':
      return '手动升级存储需要迁移后才能使用。';
    case 'available':
      return null;
    default: {
      const exhaustive: never = payload.status;
      throw new Error(`未知 manual 状态：${String(exhaustive)}`);
    }
  }
}

export function formatManualRecordSummary(
  record: ManualStatePayload['activeRecords'][number],
): string {
  return `Lv${record.fromLevel}→${record.targetLevel} · 数量 ${record.quantity}`;
}
