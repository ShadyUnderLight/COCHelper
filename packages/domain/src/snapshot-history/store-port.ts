import type { SnapshotHistoryEnvelope } from './store-types';

export type SnapshotHistoryStore = {
  readonly fileURL: string | null;
  readonly transactionJournalURL: string | null;
  load(): SnapshotHistoryEnvelope | null;
  save(envelope: SnapshotHistoryEnvelope): void;
  readRawData(): Uint8Array | null;
  writeRawData(data: Uint8Array): void;
  restoreRawData(data: Uint8Array | null): void;
};
