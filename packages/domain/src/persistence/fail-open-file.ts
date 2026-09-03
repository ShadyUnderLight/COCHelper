/**
 * fail-open 文件 store 共用读写：顶层损坏 / 缺失 → 空结果；原子写。
 */

import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname } from 'node:path';

import { atomicWriteFile } from './atomic-write';
import type { WriteFaultInjector } from './fault';
import { assertFileSizeWithinLimit, isPersistenceTooLargeError } from './limits';

export type FailOpenFileStoreOptions = {
  readonly fault?: WriteFaultInjector;
};

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
  atomicWriteFile(fileURL, data, { fault: options.fault });
}
