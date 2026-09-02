import type { SnapshotHistoryStoreError } from './errors';
import {
  validateSnapshotHistoryEntry,
  validateSnapshotHistoryEntryIntegrity,
} from './envelope-validate';
import type { SnapshotHistoryEnvelope } from './store-types';
import type { SnapshotHistoryEntry } from './types';

export type BatchCanonicalizeSnapshotHistoryResult = {
  readonly envelope: SnapshotHistoryEnvelope;
  readonly processedEntryCount: number;
};

export type BatchCanonicalizeSnapshotHistoryOptions = {
  readonly perEntry?: (entry: SnapshotHistoryEntry, index: number) => void;
  readonly validateIntegrity?: boolean;
};

/**
 * Issue #246 / #273：按 entry 校验并释放中间对象，避免 Node 加载整份历史时峰值内存线性增长。
 */
export function batchCanonicalizeSnapshotHistoryEnvelope(
  envelope: SnapshotHistoryEnvelope,
  options: BatchCanonicalizeSnapshotHistoryOptions = {},
): BatchCanonicalizeSnapshotHistoryResult {
  const validateIntegrity = options.validateIntegrity ?? true;
  const entries: SnapshotHistoryEntry[] = [];

  for (let index = 0; index < envelope.entries.length; index += 1) {
    const entry = envelope.entries[index]!;
    try {
      validateSnapshotHistoryEntry(entry, {
        validateIntegrity: validateIntegrity ? validateSnapshotHistoryEntryIntegrity : undefined,
      });
    } catch (error) {
      throw error as SnapshotHistoryStoreError;
    }
    entries.push(entry);
    options.perEntry?.(entry, index);
  }

  return {
    envelope: {
      ...envelope,
      entries,
    },
    processedEntryCount: entries.length,
  };
}

export async function batchCanonicalizeSnapshotHistoryEnvelopeAsync(
  envelope: SnapshotHistoryEnvelope,
  options: BatchCanonicalizeSnapshotHistoryOptions = {},
): Promise<BatchCanonicalizeSnapshotHistoryResult> {
  return batchCanonicalizeSnapshotHistoryEnvelope(envelope, options);
}
