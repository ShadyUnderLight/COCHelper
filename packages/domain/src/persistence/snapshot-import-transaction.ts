import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';

import type { ManualTrackerStore } from '../manual/file-store';
import {
  decodeManualTrackerEnvelopeWire,
  encodeManualTrackerEnvelopeWire,
} from '../manual/tracker-wire';
import type { ManualTrackerEnvelope } from '../manual/tracker-envelope';
import type { SnapshotHistoryStore } from '../snapshot-history/store-port';
import {
  decodeSnapshotHistoryEnvelopeWire,
  encodeSnapshotHistoryEnvelopeWire,
} from '../snapshot-history/envelope-wire';
import { validateSnapshotHistoryEnvelope } from '../snapshot-history/envelope-validate';
import { envelopeIsMigrated, type SnapshotHistoryEnvelope } from '../snapshot-history/store-types';
import { atomicWriteFile } from './atomic-write';
import { base64ToBytes, bytesToBase64 } from './bytes';
import type { WriteFaultInjector } from './fault';
import type { CurrentVillagePersistence } from './village-file-store';
import { validateVillageStoreBytes } from './village-codec';

export type SnapshotImportJournalPhase = 'prepared' | 'committed';

export type SnapshotImportJournalV1 = {
  readonly phase: SnapshotImportJournalPhase;
  readonly previousCurrentData: string | null;
  readonly newCurrentData: string;
  readonly previousHistoryData: string | null;
  readonly newHistoryData: string;
  readonly previousManualData: string | null;
  readonly manualIncluded: boolean;
  readonly newManualData: string | null;
};

export type SnapshotImportTransactionError =
  | { readonly kind: 'rollbackFailed'; readonly message: string }
  | { readonly kind: 'journalCorrupt'; readonly message: string };

export type SnapshotImportTransactionCoordinatorOptions = {
  readonly current: CurrentVillagePersistence;
  readonly history: SnapshotHistoryStore;
  readonly journalURL: string | null;
  readonly manual?: ManualTrackerStore | null;
  readonly fault?: WriteFaultInjector;
};

export class SnapshotImportTransactionCoordinator {
  private readonly current: CurrentVillagePersistence;
  private readonly history: SnapshotHistoryStore;
  private readonly journalURL: string | null;
  private readonly manual: ManualTrackerStore | null;
  private readonly fault: WriteFaultInjector | undefined;

  constructor(options: SnapshotImportTransactionCoordinatorOptions) {
    this.current = options.current;
    this.history = options.history;
    this.journalURL = options.journalURL;
    this.manual = options.manual ?? null;
    this.fault = options.fault;
  }

  recoverIfNeeded(): void {
    if (this.journalURL === null || !existsSync(this.journalURL)) {
      return;
    }

    let journal: SnapshotImportJournalV1;
    try {
      journal = JSON.parse(readFileSync(this.journalURL, 'utf8')) as SnapshotImportJournalV1;
      journal = normalizeImportJournal(journal);
    } catch (error) {
      throw {
        kind: 'journalCorrupt',
        message: error instanceof Error ? error.message : String(error),
      } satisfies SnapshotImportTransactionError;
    }

    if (journal.manualIncluded !== (journal.newManualData !== null)) {
      throw {
        kind: 'journalCorrupt',
        message: '事务记录的 manualIncluded 与手动状态 payload 不一致。',
      } satisfies SnapshotImportTransactionError;
    }
    if (!journal.manualIncluded && journal.previousManualData !== null) {
      throw {
        kind: 'journalCorrupt',
        message: '无 manual 事务的记录不应包含 previousManualData。',
      } satisfies SnapshotImportTransactionError;
    }

    try {
      validateVillageStoreBytes(
        decodeOptionalBase64(journal.previousCurrentData),
        '事务记录中的旧当前村庄数据',
      );
      validateVillageStoreBytes(
        base64ToBytes(journal.newCurrentData),
        '事务记录中的新当前村庄数据',
      );
      validateHistoryBytes(
        decodeOptionalBase64(journal.previousHistoryData),
        '事务记录中的旧历史',
      );
      validateHistoryBytes(base64ToBytes(journal.newHistoryData), '事务记录中的新历史');
    } catch (error) {
      throw asJournalCorrupt(error);
    }

    let recoveryManualStore: ManualTrackerStore | null = null;
    let recoveryManualData: Uint8Array | null = null;
    if (journal.manualIncluded) {
      if (this.manual === null) {
        throw {
          kind: 'journalCorrupt',
          message: '事务记录包含手动状态，但当前未配置手动存储。',
        } satisfies SnapshotImportTransactionError;
      }
      if (journal.newManualData === null) {
        throw {
          kind: 'journalCorrupt',
          message: '事务记录声明包含手动状态，但缺少 newManualData。',
        } satisfies SnapshotImportTransactionError;
      }
      try {
        validateManualBytes(
          decodeOptionalBase64(journal.previousManualData),
          '事务记录中的旧手动状态',
        );
        validateManualBytes(base64ToBytes(journal.newManualData), '事务记录中的新手动状态');
      } catch (error) {
        throw asJournalCorrupt(error);
      }
      recoveryManualStore = this.manual;
      recoveryManualData = base64ToBytes(journal.newManualData);
    }

    switch (journal.phase) {
      case 'prepared':
        this.current.restoreData(decodeOptionalBase64(journal.previousCurrentData));
        this.history.restoreRawData(decodeOptionalBase64(journal.previousHistoryData));
        if (recoveryManualStore !== null) {
          recoveryManualStore.restoreRawData(decodeOptionalBase64(journal.previousManualData));
        }
        break;
      case 'committed':
        this.current.writeData(base64ToBytes(journal.newCurrentData));
        this.history.writeRawData(base64ToBytes(journal.newHistoryData));
        if (recoveryManualStore !== null && recoveryManualData !== null) {
          recoveryManualStore.writeRawData(recoveryManualData);
        }
        break;
      default:
        throw {
          kind: 'journalCorrupt',
          message: `未知事务阶段：${String((journal as SnapshotImportJournalV1).phase)}`,
        } satisfies SnapshotImportTransactionError;
    }
    rmSync(this.journalURL);
  }

  commit(input: {
    readonly currentData: Uint8Array;
    readonly envelope: SnapshotHistoryEnvelope;
    readonly manualEnvelope?: ManualTrackerEnvelope | null;
  }): void {
    const newHistoryData = new TextEncoder().encode(
      encodeSnapshotHistoryEnvelopeWire(validateSnapshotHistoryEnvelope(input.envelope)),
    );
    const existingHistory = this.history.load();
    if (existingHistory === null || !envelopeIsMigrated(existingHistory)) {
      throw {
        kind: 'unavailable',
        message: '导入前未找到可用的已迁移历史。',
      };
    }

    const previousCurrentData = this.current.readData();
    const previousHistoryData = this.history.readRawData();
    if (input.manualEnvelope != null && this.manual === null) {
      throw {
        kind: 'journalCorrupt',
        message: '提交手动状态时未配置手动存储。',
      } satisfies SnapshotImportTransactionError;
    }
    const previousManualData =
      input.manualEnvelope != null ? this.manual!.readRawData() : null;
    const newManualData =
      input.manualEnvelope != null
        ? new TextEncoder().encode(encodeManualTrackerEnvelopeWire(input.manualEnvelope))
        : null;

    try {
      validateVillageStoreBytes(previousCurrentData, '旧当前村庄数据');
      validateVillageStoreBytes(input.currentData, '新当前村庄数据');
      validateHistoryBytes(previousHistoryData, '旧历史');
      validateHistoryBytes(newHistoryData, '新历史');
      if (input.manualEnvelope != null) {
        validateManualBytes(previousManualData, '旧手动状态');
        validateManualBytes(newManualData, '新手动状态');
      }
    } catch (error) {
      throw asJournalCorrupt(error);
    }

    const prepared: SnapshotImportJournalV1 = {
      phase: 'prepared',
      previousCurrentData: encodeOptionalBase64(previousCurrentData),
      newCurrentData: bytesToBase64(input.currentData),
      previousHistoryData: encodeOptionalBase64(previousHistoryData),
      newHistoryData: bytesToBase64(newHistoryData),
      previousManualData: encodeOptionalBase64(previousManualData),
      manualIncluded: input.manualEnvelope != null,
      newManualData: newManualData === null ? null : bytesToBase64(newManualData),
    };
    this.writeJournal(prepared);

    try {
      this.current.writeData(input.currentData);
      this.history.writeRawData(newHistoryData);
      if (newManualData !== null) {
        this.manual!.writeRawData(newManualData);
      }
    } catch (error) {
      try {
        this.current.restoreData(previousCurrentData);
        this.history.restoreRawData(previousHistoryData);
        if (newManualData !== null) {
          this.manual!.restoreRawData(previousManualData);
        }
        this.removeJournalIfPresent();
      } catch (rollbackError) {
        throw {
          kind: 'rollbackFailed',
          message:
            rollbackError instanceof Error ? rollbackError.message : String(rollbackError),
        } satisfies SnapshotImportTransactionError;
      }
      throw error;
    }

    if (this.journalURL === null) {
      return;
    }
    try {
      this.writeJournal({
        ...prepared,
        phase: 'committed',
      });
    } catch (error) {
      try {
        this.current.restoreData(previousCurrentData);
        this.history.restoreRawData(previousHistoryData);
        if (newManualData !== null) {
          this.manual!.restoreRawData(previousManualData);
        }
        this.removeJournalIfPresent();
      } catch (rollbackError) {
        throw {
          kind: 'rollbackFailed',
          message:
            rollbackError instanceof Error ? rollbackError.message : String(rollbackError),
        } satisfies SnapshotImportTransactionError;
      }
      throw error;
    }

    try {
      this.removeJournalIfPresent();
    } catch {
      // committed journal 本身是合法恢复记录
    }
  }

  private writeJournal(journal: SnapshotImportJournalV1): void {
    if (this.journalURL === null) {
      return;
    }
    try {
      mkdirSync(dirname(this.journalURL), { recursive: true });
      atomicWriteFile(
        this.journalURL,
        new TextEncoder().encode(JSON.stringify(journal)),
        { fault: this.fault },
      );
    } catch (error) {
      throw {
        kind: 'journalCorrupt',
        message: error instanceof Error ? error.message : String(error),
      } satisfies SnapshotImportTransactionError;
    }
  }

  private removeJournalIfPresent(): void {
    if (this.journalURL === null || !existsSync(this.journalURL)) {
      return;
    }
    rmSync(this.journalURL);
  }
}

function normalizeImportJournal(journal: SnapshotImportJournalV1): SnapshotImportJournalV1 {
  if (typeof journal.manualIncluded === 'boolean') {
    return journal;
  }
  return {
    ...journal,
    manualIncluded: journal.newManualData !== null,
  };
}

function validateHistoryBytes(data: Uint8Array | null, label: string): void {
  if (data === null) {
    return;
  }
  try {
    const envelope = decodeSnapshotHistoryEnvelopeWire(new TextDecoder().decode(data));
    validateSnapshotHistoryEnvelope(envelope, { allowUnmigratedPersistedHistory: true });
  } catch (error) {
    throw {
      kind: 'journalCorrupt',
      message: `${label} 无效：${error instanceof Error ? error.message : String(error)}`,
    } satisfies SnapshotImportTransactionError;
  }
}

function validateManualBytes(data: Uint8Array | null, label: string): void {
  if (data === null) {
    return;
  }
  try {
    decodeManualTrackerEnvelopeWire(new TextDecoder().decode(data));
  } catch (error) {
    throw {
      kind: 'journalCorrupt',
      message: `${label} 无效：${error instanceof Error ? error.message : String(error)}`,
    } satisfies SnapshotImportTransactionError;
  }
}

function encodeOptionalBase64(data: Uint8Array | null): string | null {
  return data === null ? null : bytesToBase64(data);
}

function decodeOptionalBase64(value: string | null): Uint8Array | null {
  return value === null ? null : base64ToBytes(value);
}

function asJournalCorrupt(error: unknown): SnapshotImportTransactionError {
  if (
    typeof error === 'object' &&
    error !== null &&
    'kind' in error &&
    (error as SnapshotImportTransactionError).kind === 'journalCorrupt'
  ) {
    return error as SnapshotImportTransactionError;
  }
  return {
    kind: 'journalCorrupt',
    message: error instanceof Error ? error.message : String(error),
  };
}
