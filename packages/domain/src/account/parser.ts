import { generateUuid, type UuidString } from '@coc-helper/wire';

import type { Clock, UuidSource } from '../primitives';
import { normalizeAccountItem, normalizedBoosts } from './normalize';
import { prepareAccountText } from './prepare';
import { decodeRawAccountDocument } from './raw-document';
import type { AccountDataDiagnostic, AccountSnapshot, AccountSnapshotImportError } from './types';

export type ParseAccountSnapshotOptions = {
  readonly clock: Clock;
  readonly uuid?: UuidSource;
};

export type ParseAccountSnapshotResult =
  | { readonly ok: true; readonly value: AccountSnapshot }
  | { readonly ok: false; readonly error: AccountSnapshotImportError };

export function parseAccountSnapshot(
  text: string,
  options: ParseAccountSnapshotOptions,
): ParseAccountSnapshotResult {
  const originalText = text;
  const prepared = prepareAccountText(text);
  if (prepared.text.length === 0) {
    return { ok: false, error: { kind: 'emptyInput' } };
  }
  if (!prepared.text.startsWith('{')) {
    return { ok: false, error: { kind: 'topLevelMustBeObject' } };
  }

  const raw = decodeRawAccountDocument(prepared.text);
  if ('kind' in raw) {
    return { ok: false, error: raw };
  }

  const diagnostics: AccountDataDiagnostic[] = [];
  const pushDiagnostic = (diagnostic: Omit<AccountDataDiagnostic, 'id'>): void => {
    diagnostics.push({
      ...diagnostic,
      id: nextDiagnosticId(options.uuid),
    });
  };

  if (prepared.removedCodeFence) {
    pushDiagnostic({
      severity: 'info',
      path: '文本',
      message: '已忽略外围 Markdown 代码块标记。',
    });
  }
  if (raw.tag === null || raw.tag.length === 0) {
    pushDiagnostic({
      severity: 'warning',
      path: 'tag',
      message: '缺少账号标签，快照仍可读取。',
    });
  }
  if (raw.timestamp === null) {
    pushDiagnostic({
      severity: 'warning',
      path: 'timestamp',
      message: '缺少快照时间，计时器将按原始值保留，无法自动扣除文本年龄。',
    });
  }
  if (raw.unknownTopLevelKeys.length > 0) {
    pushDiagnostic({
      severity: 'warning',
      path: '顶层',
      message: `发现未识别字段：${[...raw.unknownTopLevelKeys].sort().join('、')}`,
    });
  }
  if (
    Object.keys(raw.objectSections).length === 0 &&
    Object.keys(raw.numericSections).length === 0 &&
    Object.keys(raw.boosts).length === 0
  ) {
    pushDiagnostic({
      severity: 'warning',
      path: '顶层',
      message: '没有发现可读取的账号数据数组或加速状态。',
    });
  }

  const importedAtMs = options.clock.nowMs();
  const nowSeconds = BigInt(Math.floor(importedAtMs / 1000));
  let ageSeconds: bigint | null = null;

  if (raw.timestamp !== null && raw.timestamp > 0n) {
    if (raw.timestamp > nowSeconds) {
      pushDiagnostic({
        severity: 'warning',
        path: 'timestamp',
        message: '快照时间晚于当前时间，计时器不会被提前扣减。',
      });
      ageSeconds = 0n;
    } else {
      ageSeconds = nowSeconds - raw.timestamp;
      if (ageSeconds < 0n) {
        ageSeconds = 0n;
      }
    }
  } else if (raw.timestamp !== null) {
    pushDiagnostic({
      severity: 'warning',
      path: 'timestamp',
      message: '快照时间无效，计时器将按原始值保留。',
    });
  }

  const normalizeDiagnostics: Omit<AccountDataDiagnostic, 'id'>[] = [];
  const objectSections: Record<string, ReturnType<typeof normalizeAccountItem>[]> = {};
  for (const section of Object.keys(raw.objectSections).sort()) {
    objectSections[section] = raw.objectSections[section]!.map((item, index) =>
      normalizeAccountItem(item, section, String(index), ageSeconds, normalizeDiagnostics),
    );
  }
  const boosts = normalizedBoosts(raw.boosts, ageSeconds, normalizeDiagnostics);
  for (const diagnostic of normalizeDiagnostics) {
    pushDiagnostic(diagnostic);
  }

  return {
    ok: true,
    value: {
      tag: raw.tag,
      capturedAtMs:
        raw.timestamp === null || raw.timestamp <= 0n ? null : Number(raw.timestamp) * 1000,
      importedAtMs,
      ageSeconds,
      originalText,
      objectSections,
      numericSections: raw.numericSections,
      boosts,
      unknownTopLevelKeys: [...raw.unknownTopLevelKeys].sort(),
      diagnostics,
    },
  };
}

function nextDiagnosticId(uuid: UuidSource | undefined): UuidString {
  if (uuid !== undefined) {
    return uuid.next();
  }
  return generateUuid();
}
