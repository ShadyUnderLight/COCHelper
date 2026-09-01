export type CatalogDurationState =
  | { readonly kind: 'timed'; readonly seconds: bigint }
  | { readonly kind: 'instant' }
  | { readonly kind: 'initialLevel' }
  | { readonly kind: 'notApplicable' }
  | { readonly kind: 'sourceMissing' }
  | { readonly kind: 'parseFailed' }
  | { readonly kind: 'unknownReason'; readonly reason: string };

export function catalogDurationState(
  durationSeconds: bigint | null | undefined,
  missingReason: string | null | undefined,
): CatalogDurationState | null {
  if (durationSeconds !== null && durationSeconds !== undefined) {
    if (durationSeconds > 0n) {
      return { kind: 'timed', seconds: durationSeconds };
    }
    if (durationSeconds === 0n) {
      return { kind: 'instant' };
    }
    return { kind: 'unknownReason', reason: 'negative_duration' };
  }
  switch (missingReason) {
    case 'min_level_initial_no_upgrade':
      return { kind: 'initialLevel' };
    case 'no_time_source':
      return { kind: 'notApplicable' };
    case 'time_invalid':
      return { kind: 'parseFailed' };
    case 'time_missing':
    case 'upgrade_data_missing':
      return { kind: 'sourceMissing' };
    case undefined:
    case null:
      return null;
    default:
      return { kind: 'unknownReason', reason: missingReason };
  }
}

export function catalogDurationLabel(state: CatalogDurationState): string {
  switch (state.kind) {
    case 'timed':
      return formatDurationSeconds(state.seconds);
    case 'instant':
      return '即时';
    case 'initialLevel':
      return '初始等级，无升级时长';
    case 'notApplicable':
      return '该类别无时长数据';
    case 'sourceMissing':
      return '目录缺失';
    case 'parseFailed':
      return '目录解析失败';
    case 'unknownReason':
      return '暂无目录数据';
  }
}

function formatDurationSeconds(totalSeconds: bigint): string {
  const seconds = Number(totalSeconds);
  if (!Number.isFinite(seconds) || seconds < 0) {
    return '暂无目录数据';
  }
  const days = Math.floor(seconds / 86_400);
  const hours = Math.floor((seconds % 86_400) / 3_600);
  const minutes = Math.floor((seconds % 3_600) / 60);
  const remaining = seconds % 60;
  const parts: string[] = [];
  if (days > 0) {
    parts.push(`${days}天`);
  }
  if (hours > 0) {
    parts.push(`${hours}小时`);
  }
  if (minutes > 0) {
    parts.push(`${minutes}分钟`);
  }
  if (remaining > 0 || parts.length === 0) {
    parts.push(`${remaining}秒`);
  }
  return parts.join('');
}
