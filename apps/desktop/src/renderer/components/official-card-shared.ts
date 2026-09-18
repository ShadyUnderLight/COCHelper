import type { OfficialRefreshStatus } from '../official-session';

export function officialStatusClass(
  status: OfficialRefreshStatus | null,
): 'muted' | 'notice-text' | 'error-text' | 'official-ok' {
  switch (status) {
    case 'stale':
      return 'notice-text';
    case 'failedWithLastGood':
    case 'failedWithoutLastGood':
      return 'error-text';
    case 'success':
      return 'official-ok';
    default:
      return 'muted';
  }
}
