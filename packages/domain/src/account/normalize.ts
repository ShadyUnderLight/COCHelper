import type { AccountDataDiagnostic, AccountItem } from './types';
import type { RawAccountItem } from './raw-document';

type TimerPair = {
  readonly raw: bigint | null;
  readonly remaining: bigint | null;
};

export function normalizeAccountItem(
  item: RawAccountItem,
  section: string,
  path: string,
  ageSeconds: bigint | null,
  diagnostics: Omit<AccountDataDiagnostic, 'id'>[],
): AccountItem {
  const timer = adjustedTimer(
    item.timerSeconds,
    ageSeconds,
    `${section}[${path}].timer`,
    diagnostics,
  );
  const helperTimer = adjustedTimer(
    item.helperTimerSeconds,
    ageSeconds,
    `${section}[${path}].helper_timer`,
    diagnostics,
  );
  const helperCooldown = adjustedDuration(
    item.helperCooldownSeconds,
    ageSeconds,
    `${section}[${path}].helper_cooldown`,
    diagnostics,
  );

  const types = item.types.map((child, index) =>
    normalizeAccountItem(child, section, `${path}.types.${index}`, ageSeconds, diagnostics),
  );
  const modules = item.modules.map((child, index) =>
    normalizeAccountItem(child, section, `${path}.modules.${index}`, ageSeconds, diagnostics),
  );

  return {
    id: `${section}:${path}`,
    section,
    dataID: item.dataID,
    level: item.level,
    count: item.count,
    timerSeconds: timer.raw,
    remainingSeconds: timer.remaining,
    helperTimerSeconds: helperTimer.raw,
    remainingHelperSeconds: helperTimer.remaining,
    helperCooldownSeconds: item.helperCooldownSeconds,
    remainingHelperCooldownSeconds: helperCooldown,
    helperRecurrent: item.helperRecurrent,
    gearUp: item.gearUp,
    weapon: item.weapon,
    types,
    modules,
  };
}

export function normalizedBoosts(
  boosts: Readonly<Record<string, bigint>>,
  ageSeconds: bigint | null,
  diagnostics: Omit<AccountDataDiagnostic, 'id'>[],
): Record<string, bigint> {
  const normalized: Record<string, bigint> = {};
  for (const key of Object.keys(boosts).sort()) {
    normalized[key] =
      adjustedDuration(boosts[key]!, ageSeconds, `boosts.${key}`, diagnostics) ?? 0n;
  }
  return normalized;
}

function adjustedTimer(
  raw: bigint | null,
  ageSeconds: bigint | null,
  path: string,
  diagnostics: Omit<AccountDataDiagnostic, 'id'>[],
): TimerPair {
  if (raw === null) {
    return { raw: null, remaining: null };
  }
  if (raw < 0n) {
    diagnostics.push({
      severity: 'warning',
      path,
      message: '计时器为负数，已按 0 秒处理。',
    });
    return { raw, remaining: 0n };
  }
  if (ageSeconds === null) {
    return { raw, remaining: raw };
  }
  const remaining = raw - ageSeconds;
  return { raw, remaining: remaining > 0n ? remaining : 0n };
}

function adjustedDuration(
  raw: bigint | null,
  ageSeconds: bigint | null,
  path: string,
  diagnostics: Omit<AccountDataDiagnostic, 'id'>[],
): bigint | null {
  if (raw === null) {
    return null;
  }
  if (raw < 0n) {
    diagnostics.push({
      severity: 'warning',
      path,
      message: '时长为负数，已按 0 秒处理。',
    });
    return 0n;
  }
  if (ageSeconds === null) {
    return raw;
  }
  const remaining = raw - ageSeconds;
  return remaining > 0n ? remaining : 0n;
}
