import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';

import { unixSecondsToRefSeconds } from '@coc-helper/wire';

import { atomicWriteFile } from '../persistence/atomic-write';
import {
  PERSISTENCE_FILE_NAMES,
  resolveElectronDataRoot,
} from '../persistence/data-root';
import type { WriteFaultInjector } from '../persistence/fault';
import type { SnapshotHistoryStoreError } from './errors';
import {
  decodeSnapshotHistoryEnvelopeWire,
  encodeSnapshotHistoryEnvelopeWire,
} from './envelope-wire';
import {
  hydrateSnapshotHistoryEnvelope,
  validateSnapshotHistoryEnvelope,
} from './envelope-validate';
import type { SnapshotHistoryEnvelope } from './store-types';
import type { SnapshotCoverageRevalidationPolicy } from './store-types';
import type { SnapshotHistoryStore } from './store-port';

export function defaultSnapshotHistoryFileURL(homeDirectory?: string): string | null {
  const root = resolveElectronDataRoot(homeDirectory);
  return root === null ? null : join(root, PERSISTENCE_FILE_NAMES.snapshotHistory);
}

export type FileSnapshotHistoryStoreOptions = {
  readonly hydrationPolicy?: SnapshotCoverageRevalidationPolicy;
  readonly fault?: WriteFaultInjector;
};

export class FileSnapshotHistoryStore implements SnapshotHistoryStore {
  readonly fileURL: string | null;
  readonly transactionJournalURL: string | null;
  private readonly hydrationPolicy: SnapshotCoverageRevalidationPolicy;
  private readonly fault: WriteFaultInjector | undefined;

  constructor(fileURL: string | null, options: FileSnapshotHistoryStoreOptions = {}) {
    this.fileURL = fileURL;
    this.transactionJournalURL =
      fileURL === null
        ? null
        : join(dirname(fileURL), PERSISTENCE_FILE_NAMES.snapshotHistoryJournal);
    this.hydrationPolicy = options.hydrationPolicy ?? 'production';
    this.fault = options.fault;
  }

  load(): SnapshotHistoryEnvelope | null {
    const data = this.readRawData();
    if (data === null) {
      return null;
    }
    try {
      const envelope = decodeSnapshotHistoryEnvelopeWire(new TextDecoder().decode(data));
      const validated = validateSnapshotHistoryEnvelope(envelope, {
        allowUnmigratedPersistedHistory: true,
      });
      return hydrateSnapshotHistoryEnvelope(validated, this.hydrationPolicy);
    } catch (error) {
      if (isSnapshotHistoryStoreError(error)) {
        throw error;
      }
      throw storeError({
        kind: 'corrupt',
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  save(envelope: SnapshotHistoryEnvelope): void {
    try {
      const validated = validateSnapshotHistoryEnvelope(envelope);
      const encoded = encodeSnapshotHistoryEnvelopeWire(validated);
      this.writeRawData(new TextEncoder().encode(encoded));
    } catch (error) {
      if (isSnapshotHistoryStoreError(error)) {
        throw error;
      }
      throw storeError({
        kind: 'writeFailed',
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  readRawData(): Uint8Array | null {
    if (this.fileURL === null) {
      throw storeError({ kind: 'unavailable', message: '没有可用的历史文件路径。' });
    }
    if (!existsSync(this.fileURL)) {
      return null;
    }
    try {
      return readFileSync(this.fileURL);
    } catch (error) {
      throw storeError({
        kind: 'unavailable',
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  writeRawData(data: Uint8Array): void {
    if (this.fileURL === null) {
      throw storeError({ kind: 'unavailable', message: '没有可用的历史文件路径。' });
    }
    try {
      mkdirSync(dirname(this.fileURL), { recursive: true });
      atomicWriteFile(this.fileURL, data, { fault: this.fault });
    } catch (error) {
      throw storeError({
        kind: 'writeFailed',
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  restoreRawData(data: Uint8Array | null): void {
    if (this.fileURL === null) {
      throw storeError({ kind: 'unavailable', message: '没有可用的历史文件路径。' });
    }
    try {
      if (data !== null) {
        mkdirSync(dirname(this.fileURL), { recursive: true });
        atomicWriteFile(this.fileURL, data, { fault: this.fault });
      } else if (existsSync(this.fileURL)) {
        rmSync(this.fileURL);
      }
    } catch (error) {
      throw storeError({
        kind: 'writeFailed',
        message: `回滚历史文件失败：${error instanceof Error ? error.message : String(error)}`,
      });
    }
  }
}

export function createInMemorySnapshotHistoryStore(): SnapshotHistoryStore & {
  readonly snapshot: () => Uint8Array | null;
} {
  let bytes: Uint8Array | null = null;
  const fileURL = '/memory/snapshot-history-v1.json';
  return {
    fileURL,
    transactionJournalURL: join(
      dirname(fileURL),
      PERSISTENCE_FILE_NAMES.snapshotHistoryJournal,
    ),
    load(): SnapshotHistoryEnvelope | null {
      if (bytes === null) {
        return null;
      }
      const envelope = decodeSnapshotHistoryEnvelopeWire(new TextDecoder().decode(bytes));
      const validated = validateSnapshotHistoryEnvelope(envelope, {
        allowUnmigratedPersistedHistory: true,
      });
      return hydrateSnapshotHistoryEnvelope(validated, 'testsAllowTestFixture');
    },
    save(envelope: SnapshotHistoryEnvelope): void {
      const validated = validateSnapshotHistoryEnvelope(envelope);
      bytes = new TextEncoder().encode(encodeSnapshotHistoryEnvelopeWire(validated));
    },
    readRawData(): Uint8Array | null {
      return bytes === null ? null : new Uint8Array(bytes);
    },
    writeRawData(data: Uint8Array): void {
      bytes = new Uint8Array(data);
    },
    restoreRawData(data: Uint8Array | null): void {
      bytes = data === null ? null : new Uint8Array(data);
    },
    snapshot(): Uint8Array | null {
      return bytes === null ? null : new Uint8Array(bytes);
    },
  };
}

export function nowAppliedAtRefSeconds(nowMs: number = Date.now()): number {
  return unixSecondsToRefSeconds(nowMs / 1000);
}

function storeError(error: SnapshotHistoryStoreError): SnapshotHistoryStoreError {
  return error;
}

function isSnapshotHistoryStoreError(error: unknown): error is SnapshotHistoryStoreError {
  return (
    typeof error === 'object' &&
    error !== null &&
    'kind' in error &&
    typeof (error as SnapshotHistoryStoreError).kind === 'string'
  );
}
