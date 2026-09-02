import type { SnapshotHistoryStoreError } from './errors';
import {
  validateSnapshotHistoryEntry,
  validateSnapshotHistoryEntryIntegrity,
} from './envelope-validate';
import type { SnapshotHistoryEnvelope } from './store-types';
import type { SnapshotHistoryEntry } from './types';

export type SequentialValidateSnapshotHistoryResult = {
  readonly processedEntryCount: number;
};

export type SequentialValidateSnapshotHistoryOptions = {
  readonly perEntry?: (entry: SnapshotHistoryEntry, index: number) => void;
  readonly validateIntegrity?: boolean;
  /** async 版本每处理若干 entry 后让出事件循环（非 streaming load）。 */
  readonly yieldEvery?: number;
};

/**
 * 按 entry 顺序校验 envelope，不在此函数内复制或重建 entries 数组。
 * 有界内存 load 需由 E3-01 存储层 streaming reader 配合；本 helper 仅保证
 * 校验阶段不额外 materialize 第二份 entries[]。
 */
export function sequentialValidateSnapshotHistoryEntries(
  envelope: SnapshotHistoryEnvelope,
  options: SequentialValidateSnapshotHistoryOptions = {},
): SequentialValidateSnapshotHistoryResult {
  const validateIntegrity = options.validateIntegrity ?? true;

  for (let index = 0; index < envelope.entries.length; index += 1) {
    const entry = envelope.entries[index]!;
    try {
      validateSnapshotHistoryEntry(entry, {
        validateIntegrity: validateIntegrity ? validateSnapshotHistoryEntryIntegrity : undefined,
      });
    } catch (error) {
      throw error as SnapshotHistoryStoreError;
    }
    options.perEntry?.(entry, index);
  }

  return { processedEntryCount: envelope.entries.length };
}

export async function sequentialValidateSnapshotHistoryEntriesAsync(
  envelope: SnapshotHistoryEnvelope,
  options: SequentialValidateSnapshotHistoryOptions = {},
): Promise<SequentialValidateSnapshotHistoryResult> {
  const yieldEvery = options.yieldEvery ?? 16;
  const validateIntegrity = options.validateIntegrity ?? true;

  for (let index = 0; index < envelope.entries.length; index += 1) {
    const entry = envelope.entries[index]!;
    try {
      validateSnapshotHistoryEntry(entry, {
        validateIntegrity: validateIntegrity ? validateSnapshotHistoryEntryIntegrity : undefined,
      });
    } catch (error) {
      throw error as SnapshotHistoryStoreError;
    }
    options.perEntry?.(entry, index);
    if (yieldEvery > 0 && (index + 1) % yieldEvery === 0) {
      await new Promise<void>((resolve) => {
        setImmediate(resolve);
      });
    }
  }

  return { processedEntryCount: envelope.entries.length };
}
