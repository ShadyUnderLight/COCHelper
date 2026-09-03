/**
 * fail-open 文件 store 共用读写：顶层损坏 / 缺失 → 空结果；原子写。
 */

import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname } from 'node:path';

import { atomicWriteFile } from './atomic-write';
import type { WriteFaultInjector } from './fault';
import {
  assertFileSizeWithinLimit,
  isPersistenceTooLargeError,
  PERSISTENCE_MAX_FILE_BYTES,
  type PersistenceReadError,
} from './limits';
import { OFFICIAL_STATE_STORE_MAX_ENTRIES } from '../official/official-state-store';

export type FailOpenFileStoreOptions = {
  readonly fault?: WriteFaultInjector;
  readonly maxBytes?: number;
};

export type FailOpenWriteError =
  | Extract<PersistenceReadError, { kind: 'tooLarge' }>
  | { readonly kind: 'tooManyEntries'; readonly message: string; readonly count: number };

export function isFailOpenWriteError(error: unknown): error is FailOpenWriteError {
  return (
    typeof error === 'object' &&
    error !== null &&
    'kind' in error &&
    ((error as FailOpenWriteError).kind === 'tooLarge' ||
      (error as FailOpenWriteError).kind === 'tooManyEntries')
  );
}

export function assertFailOpenEntryCount(count: number): void {
  if (count > OFFICIAL_STATE_STORE_MAX_ENTRIES) {
    throw {
      kind: 'tooManyEntries',
      message: `条目数超过上限（${String(OFFICIAL_STATE_STORE_MAX_ENTRIES)}）。`,
      count,
    } satisfies FailOpenWriteError;
  }
}

export function readFailOpenJsonFile(fileURL: string | null): unknown | null {
  if (fileURL === null || !existsSync(fileURL)) {
    return null;
  }
  try {
    assertFileSizeWithinLimit(fileURL);
    return JSON.parse(readFileSync(fileURL, 'utf8')) as unknown;
  } catch (error) {
    if (isPersistenceTooLargeError(error)) {
      return null;
    }
    return null;
  }
}

export function writeFailOpenJsonFile(
  fileURL: string | null,
  value: unknown,
  options: FailOpenFileStoreOptions = {},
): void {
  if (fileURL === null) {
    throw new Error('没有可用的 fail-open 文件路径。');
  }
  mkdirSync(dirname(fileURL), { recursive: true });
  const data = new TextEncoder().encode(`${JSON.stringify(value)}\n`);
  const maxBytes = options.maxBytes ?? PERSISTENCE_MAX_FILE_BYTES;
  if (data.byteLength > maxBytes) {
    throw {
      kind: 'tooLarge',
      message: `文件超过大小上限（${String(maxBytes)} bytes）。`,
      size: data.byteLength,
    } satisfies PersistenceReadError;
  }
  atomicWriteFile(fileURL, data, { fault: options.fault });
}
