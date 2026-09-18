import type { DiagnosticsSnapshotPayload } from '@coc-helper/contracts';

import type { ResourceState } from './resource-state';

export type DiagnosticsState = ResourceState<DiagnosticsSnapshotPayload>;

export function diagnosticsApplicationLabel(
  availability: DiagnosticsSnapshotPayload['application']['availability'],
): string {
  switch (availability) {
    case 'loading':
      return '加载中';
    case 'available':
      return '可用';
    case 'recovery':
      return '需要恢复';
    case 'unavailable':
      return '不可用';
    default: {
      const exhaustive: never = availability;
      throw new Error(`未知应用状态：${String(exhaustive)}`);
    }
  }
}

export function diagnosticsResourceErrorText(state: DiagnosticsState): string | null {
  switch (state.kind) {
    case 'failed':
      return `诊断加载失败：${state.error.message}`;
    case 'failedWithLastGood':
      return `诊断刷新失败，已保留上次成功诊断：${state.error.message}`;
    default:
      return null;
  }
}
