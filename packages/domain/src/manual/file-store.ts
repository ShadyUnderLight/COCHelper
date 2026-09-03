import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';

import type { ManualTrackerStoreError } from './errors';
import { type ManualTrackerEnvelope, validateManualTrackerEnvelope } from './tracker-envelope';
import { decodeManualTrackerEnvelopeWire, encodeManualTrackerEnvelopeWire } from './tracker-wire';
import { atomicWriteFile } from '../persistence/atomic-write';
import { PERSISTENCE_FILE_NAMES, resolveElectronDataRoot } from '../persistence/data-root';
import type { WriteFaultInjector } from '../persistence/fault';
import { assertFileSizeWithinLimit, isPersistenceTooLargeError } from '../persistence/limits';

export type ManualTrackerStore = {
  readonly fileURL: string | null;
  readonly transactionJournalURL: string | null;
  load(): ManualTrackerEnvelope | null;
  save(envelope: ManualTrackerEnvelope): void;
  readRawData(): Uint8Array | null;
  writeRawData(data: Uint8Array): void;
  restoreRawData(data: Uint8Array | null): void;
};

export type FileManualTrackerStoreOptions = {
  readonly fault?: WriteFaultInjector;
};

export function defaultManualTrackerFileURL(homeDirectory?: string): string | null {
  const root = resolveElectronDataRoot(homeDirectory);
  return root === null ? null : join(root, PERSISTENCE_FILE_NAMES.manualTracker);
}

export class FileManualTrackerStore implements ManualTrackerStore {
  readonly fileURL: string | null;
  readonly transactionJournalURL: string | null;
  private readonly fault: WriteFaultInjector | undefined;

  constructor(fileURL: string | null, options: FileManualTrackerStoreOptions = {}) {
    this.fileURL = fileURL;
    this.transactionJournalURL =
      fileURL === null ? null : join(dirname(fileURL), PERSISTENCE_FILE_NAMES.manualTrackerJournal);
    this.fault = options.fault;
  }

  load(): ManualTrackerEnvelope | null {
    const data = this.readRawData();
    if (data === null) {
      return null;
    }
    try {
      return decodeManualTrackerEnvelopeWire(new TextDecoder().decode(data));
    } catch (error) {
      if (isManualTrackerStoreError(error)) {
        throw error;
      }
      throw {
        kind: 'corrupt',
        message: error instanceof Error ? error.message : String(error),
      } satisfies ManualTrackerStoreError;
    }
  }

  save(envelope: ManualTrackerEnvelope): void {
    try {
      const validated = validateManualTrackerEnvelope(envelope);
      const encoded = encodeManualTrackerEnvelopeWire(validated);
      this.writeRawData(new TextEncoder().encode(encoded));
    } catch (error) {
      if (isManualTrackerStoreError(error)) {
        throw error;
      }
      throw {
        kind: 'writeFailed',
        message: error instanceof Error ? error.message : String(error),
      } satisfies ManualTrackerStoreError;
    }
  }

  readRawData(): Uint8Array | null {
    if (this.fileURL === null) {
      throw {
        kind: 'unavailable',
        message: '没有可用的手动升级文件路径。',
      } satisfies ManualTrackerStoreError;
    }
    if (!existsSync(this.fileURL)) {
      return null;
    }
    try {
      assertFileSizeWithinLimit(this.fileURL);
      return readFileSync(this.fileURL);
    } catch (error) {
      if (isManualTrackerStoreError(error)) {
        throw error;
      }
      if (isPersistenceTooLargeError(error)) {
        throw {
          kind: 'unavailable',
          message: error.message,
        } satisfies ManualTrackerStoreError;
      }
      throw {
        kind: 'unavailable',
        message: error instanceof Error ? error.message : String(error),
      } satisfies ManualTrackerStoreError;
    }
  }

  writeRawData(data: Uint8Array): void {
    if (this.fileURL === null) {
      throw {
        kind: 'unavailable',
        message: '没有可用的手动升级文件路径。',
      } satisfies ManualTrackerStoreError;
    }
    try {
      mkdirSync(dirname(this.fileURL), { recursive: true });
      atomicWriteFile(this.fileURL, data, { fault: this.fault });
    } catch (error) {
      throw {
        kind: 'writeFailed',
        message: error instanceof Error ? error.message : String(error),
      } satisfies ManualTrackerStoreError;
    }
  }

  restoreRawData(data: Uint8Array | null): void {
    if (this.fileURL === null) {
      throw {
        kind: 'unavailable',
        message: '没有可用的手动升级文件路径。',
      } satisfies ManualTrackerStoreError;
    }
    try {
      if (data !== null) {
        mkdirSync(dirname(this.fileURL), { recursive: true });
        atomicWriteFile(this.fileURL, data, { fault: this.fault });
      } else if (existsSync(this.fileURL)) {
        rmSync(this.fileURL);
      }
    } catch (error) {
      throw {
        kind: 'writeFailed',
        message: `回滚手动升级文件失败：${error instanceof Error ? error.message : String(error)}`,
      } satisfies ManualTrackerStoreError;
    }
  }
}

export function createInMemoryManualTrackerStore(): ManualTrackerStore & {
  readonly snapshot: () => Uint8Array | null;
} {
  let bytes: Uint8Array | null = null;
  const fileURL = '/memory/manual-tracker-v1.json';
  return {
    fileURL,
    transactionJournalURL: join(dirname(fileURL), PERSISTENCE_FILE_NAMES.manualTrackerJournal),
    load(): ManualTrackerEnvelope | null {
      if (bytes === null) {
        return null;
      }
      return decodeManualTrackerEnvelopeWire(new TextDecoder().decode(bytes));
    },
    save(envelope: ManualTrackerEnvelope): void {
      const validated = validateManualTrackerEnvelope(envelope);
      bytes = new TextEncoder().encode(encodeManualTrackerEnvelopeWire(validated));
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

function isManualTrackerStoreError(error: unknown): error is ManualTrackerStoreError {
  return (
    typeof error === 'object' &&
    error !== null &&
    'kind' in error &&
    typeof (error as ManualTrackerStoreError).kind === 'string'
  );
}
