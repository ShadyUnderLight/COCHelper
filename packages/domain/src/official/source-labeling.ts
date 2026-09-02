import type { OfficialAPIRequestStatus } from './types';

/** 官方数据来源标签（对齐 OfficialAPISourceLabeling.swift）。 */
export function officialAPISourceLabel(
  status: OfficialAPIRequestStatus,
  hasLastGood: boolean,
): string | undefined {
  switch (status) {
    case 'success':
      return 'official-api';
    case 'failed':
      return hasLastGood ? 'cached-official-api' : undefined;
    case 'never':
    case 'loading':
    case 'skipped':
      return undefined;
  }
}
