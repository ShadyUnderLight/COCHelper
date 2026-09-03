import { existsSync, readdirSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';

/** 单文件读取上限（含 journal / store JSON）。 */
export const PERSISTENCE_MAX_FILE_BYTES = 32 * 1024 * 1024;

/** 原子写临时文件名：.<basename>.<pid>.<timestamp>.tmp */
const ATOMIC_TEMP_NAME = /^\..+\.\d+\.\d+\.tmp$/;

export type PersistenceReadError =
  | { readonly kind: 'unavailable'; readonly message: string }
  | { readonly kind: 'tooLarge'; readonly message: string; readonly size: number };

export function isPersistenceTooLargeError(
  error: unknown,
): error is Extract<PersistenceReadError, { kind: 'tooLarge' }> {
  return (
    typeof error === 'object' &&
    error !== null &&
    'kind' in error &&
    (error as PersistenceReadError).kind === 'tooLarge' &&
    'message' in error &&
    typeof (error as { message: unknown }).message === 'string'
  );
}

/**
 * 启动时清理 data root 内因 kill 残留的原子写临时文件。
 * 正常失败路径已在 atomicWriteFile catch 中删除；此处覆盖 rename 前被 SIGKILL 的情况。
 */
export function cleanupOrphanAtomicTempFiles(directory: string): string[] {
  if (!existsSync(directory)) {
    return [];
  }
  const removed: string[] = [];
  for (const name of readdirSync(directory)) {
    if (!ATOMIC_TEMP_NAME.test(name)) {
      continue;
    }
    const fullPath = join(directory, name);
    try {
      if (!statSync(fullPath).isFile()) {
        continue;
      }
      rmSync(fullPath, { force: true });
      removed.push(fullPath);
    } catch {
      // best-effort
    }
  }
  return removed;
}

export function assertFileSizeWithinLimit(
  filePath: string,
  maxBytes: number = PERSISTENCE_MAX_FILE_BYTES,
): void {
  const size = statSync(filePath).size;
  if (size > maxBytes) {
    throw {
      kind: 'tooLarge',
      message: `文件超过大小上限（${String(maxBytes)} bytes）。`,
      size,
    } satisfies PersistenceReadError;
  }
}
