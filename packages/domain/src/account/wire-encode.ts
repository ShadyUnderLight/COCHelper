import { unixSecondsToRefSeconds } from '@coc-helper/wire';

import type { AccountDataDiagnostic, AccountItem, AccountSnapshot } from './types';

/** Swift JSONEncoder + sortedKeys 的 AccountSnapshot wire 形状。 */
export function encodeAccountSnapshotWire(snapshot: AccountSnapshot): string {
  return encodeSwiftSortedJson({
    tag: snapshot.tag,
    capturedAt:
      snapshot.capturedAtMs === null
        ? undefined
        : unixSecondsToRefSeconds(snapshot.capturedAtMs / 1000),
    importedAt: unixSecondsToRefSeconds(snapshot.importedAtMs / 1000),
    ageSeconds: snapshot.ageSeconds === null ? undefined : bigintToWireNumber(snapshot.ageSeconds),
    originalText: snapshot.originalText,
    objectSections: mapObjectSectionsForWire(snapshot.objectSections),
    numericSections: mapNumericSectionsForWire(snapshot.numericSections),
    boosts: mapBoostsForWire(snapshot.boosts),
    unknownTopLevelKeys: [...snapshot.unknownTopLevelKeys],
    diagnostics: snapshot.diagnostics.map(encodeDiagnostic),
  });
}

export function encodeSwiftSortedJson(value: unknown): string {
  return `${JSON.stringify(encodeValue(value))}`;
}

export function mapObjectSectionsForWire(
  sections: Readonly<Record<string, readonly AccountItem[]>>,
): Record<string, unknown[]> {
  const result: Record<string, unknown[]> = {};
  for (const key of Object.keys(sections).sort()) {
    result[key] = sections[key]!.map(encodeAccountItem);
  }
  return result;
}

export function mapNumericSectionsForWire(
  sections: Readonly<Record<string, readonly bigint[]>>,
): Record<string, number[]> {
  const result: Record<string, number[]> = {};
  for (const key of Object.keys(sections).sort()) {
    result[key] = sections[key]!.map((value) => bigintToWireNumber(value));
  }
  return result;
}

export function mapBoostsForWire(boosts: Readonly<Record<string, bigint>>): Record<string, number> {
  const result: Record<string, number> = {};
  for (const key of Object.keys(boosts).sort()) {
    result[key] = bigintToWireNumber(boosts[key]!);
  }
  return result;
}

function encodeAccountItem(item: AccountItem): Record<string, unknown> {
  const encoded: Record<string, unknown> = {
    dataID: bigintToWireNumber(item.dataID),
    helperRecurrent: item.helperRecurrent,
    id: item.id,
    modules: item.modules.map(encodeAccountItem),
    section: item.section,
    types: item.types.map(encodeAccountItem),
  };
  if (item.level !== null) {
    encoded.level = item.level;
  }
  if (item.count !== null) {
    encoded.count = item.count;
  }
  if (item.timerSeconds !== null) {
    encoded.timerSeconds = bigintToWireNumber(item.timerSeconds);
  }
  if (item.remainingSeconds !== null) {
    encoded.remainingSeconds = bigintToWireNumber(item.remainingSeconds);
  }
  if (item.helperTimerSeconds !== null) {
    encoded.helperTimerSeconds = bigintToWireNumber(item.helperTimerSeconds);
  }
  if (item.remainingHelperSeconds !== null) {
    encoded.remainingHelperSeconds = bigintToWireNumber(item.remainingHelperSeconds);
  }
  if (item.helperCooldownSeconds !== null) {
    encoded.helperCooldownSeconds = bigintToWireNumber(item.helperCooldownSeconds);
  }
  if (item.remainingHelperCooldownSeconds !== null) {
    encoded.remainingHelperCooldownSeconds = bigintToWireNumber(
      item.remainingHelperCooldownSeconds,
    );
  }
  if (item.gearUp !== null) {
    encoded.gearUp = item.gearUp;
  }
  if (item.weapon !== null) {
    encoded.weapon = item.weapon;
  }
  return encoded;
}

function encodeDiagnostic(diagnostic: AccountDataDiagnostic): Record<string, unknown> {
  return {
    id: diagnostic.id,
    message: diagnostic.message,
    path: diagnostic.path,
    severity: diagnostic.severity,
  };
}

function encodeValue(value: unknown): unknown {
  if (value === undefined) {
    return undefined;
  }
  if (value === null) {
    return null;
  }
  if (typeof value === 'bigint') {
    return bigintToWireNumber(value);
  }
  if (Array.isArray(value)) {
    return value.map((entry) => encodeValue(entry));
  }
  if (typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const encoded: Record<string, unknown> = {};
    for (const key of Object.keys(record).sort()) {
      const entry = encodeValue(record[key]);
      if (entry !== undefined) {
        encoded[key] = entry;
      }
    }
    return encoded;
  }
  return value;
}

function bigintToWireNumber(value: bigint): number {
  const asNumber = Number(value);
  if (!Number.isSafeInteger(asNumber) || BigInt(asNumber) !== value) {
    throw new RangeError(`wire 编码超出 JS safe integer：${value.toString()}`);
  }
  return asNumber;
}

export function wireHex(snapshot: AccountSnapshot): string {
  const bytes = new TextEncoder().encode(encodeAccountSnapshotWire(snapshot));
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}
