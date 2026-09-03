import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';

import type { ManualTrackerStore } from '../manual/file-store';
import {
  decodeManualTrackerEnvelopeWire,
  encodeManualTrackerEnvelopeWire,
} from '../manual/tracker-wire';
import type { ManualTrackerEnvelope } from '../manual/tracker-envelope';
import { atomicWriteFile } from './atomic-write';
import { base64ToBytes, bytesToBase64 } from './bytes';
import type { WriteFaultInjector } from './fault';
import type { CurrentVillagePersistence } from './village-file-store';
import { validateVillageStoreBytes } from './village-codec';

export type ManualTrackerJournalPhase = 'prepared' | 'committed';

export type TrackerJournalV1 = {
  readonly phase: ManualTrackerJournalPhase;
  readonly previousCurrentData: string | null;
  readonly newCurrentData: string;
  readonly previousManualData: string | null;
  readonly newManualData: string;
};

export type ManualTrackerTransactionError =
  | { readonly kind: 'rollbackFailed'; readonly message: string }
  | { readonly kind: 'journalCorrupt'; readonly message: string }
  | { readonly kind: 'journalWriteFailed'; readonly message: string };

export type ManualTrackerTransactionCoordinatorOptions = {
  readonly current: CurrentVillagePersistence;
  readonly manual: ManualTrackerStore;
  readonly journalURL: string | null;
  readonly fault?: WriteFaultInjector;
};

export class ManualTrackerTransactionCoordinator {
  private readonly current: CurrentVillagePersistence;
  private readonly manual: ManualTrackerStore;
  private readonly journalURL: string | null;
  private readonly fault: WriteFaultInjector | undefined;

  constructor(options: ManualTrackerTransactionCoordinatorOptions) {
    this.current = options.current;
    this.manual = options.manual;
    this.journalURL = options.journalURL;
    this.fault = options.fault;
  }

  recoverIfNeeded(): void {
    if (this.journalURL === null || !existsSync(this.journalURL)) {
      return;
    }

    let journal: TrackerJournalV1;
    try {
      journal = JSON.parse(readFileSync(this.journalURL, 'utf8')) as TrackerJournalV1;
    } catch (error) {
      throw {
        kind: 'journalCorrupt',
        message: error instanceof Error ? error.message : String(error),
      } satisfies ManualTrackerTransactionError;
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
      validateManualBytes(
        decodeOptionalBase64(journal.previousManualData),
        '事务记录中的旧手动状态',
      );
      validateManualBytes(base64ToBytes(journal.newManualData), '事务记录中的新手动状态');
    } catch (error) {
      throw {
        kind: 'journalCorrupt',
        message: error instanceof Error ? error.message : String(error),
      } satisfies ManualTrackerTransactionError;
    }

    switch (journal.phase) {
      case 'prepared':
        this.restore(
          decodeOptionalBase64(journal.previousCurrentData),
          decodeOptionalBase64(journal.previousManualData),
        );
        break;
      case 'committed':
        this.current.writeData(base64ToBytes(journal.newCurrentData));
        this.manual.writeRawData(base64ToBytes(journal.newManualData));
        break;
      default:
        throw {
          kind: 'journalCorrupt',
          message: `未知事务阶段：${String((journal as TrackerJournalV1).phase)}`,
        } satisfies ManualTrackerTransactionError;
    }
    rmSync(this.journalURL);
  }

  commit(input: {
    readonly currentData: Uint8Array;
    readonly envelope: ManualTrackerEnvelope;
  }): void {
    const newManualData = new TextEncoder().encode(encodeManualTrackerEnvelopeWire(input.envelope));
    const previousCurrentData = this.current.readData();
    const previousManualData = this.manual.readRawData();
    try {
      validateVillageStoreBytes(previousCurrentData, '旧当前村庄数据');
      validateVillageStoreBytes(input.currentData, '新当前村庄数据');
      validateManualBytes(previousManualData, '旧手动状态');
      validateManualBytes(newManualData, '新手动状态');
    } catch (error) {
      throw {
        kind: 'journalCorrupt',
        message: error instanceof Error ? error.message : String(error),
      } satisfies ManualTrackerTransactionError;
    }

    const prepared: TrackerJournalV1 = {
      phase: 'prepared',
      previousCurrentData: encodeOptionalBase64(previousCurrentData),
      newCurrentData: bytesToBase64(input.currentData),
      previousManualData: encodeOptionalBase64(previousManualData),
      newManualData: bytesToBase64(newManualData),
    };
    this.writeJournal(prepared);

    try {
      this.current.writeData(input.currentData);
      this.manual.writeRawData(newManualData);
    } catch (error) {
      try {
        this.restore(previousCurrentData, previousManualData);
        this.removeJournalIfPresent();
      } catch (rollbackError) {
        throw {
          kind: 'rollbackFailed',
          message: rollbackError instanceof Error ? rollbackError.message : String(rollbackError),
        } satisfies ManualTrackerTransactionError;
      }
      throw error;
    }

    if (this.journalURL === null) {
      return;
    }
    try {
      this.writeJournal({ ...prepared, phase: 'committed' });
    } catch (error) {
      try {
        this.restore(previousCurrentData, previousManualData);
        this.removeJournalIfPresent();
      } catch (rollbackError) {
        throw {
          kind: 'rollbackFailed',
          message: rollbackError instanceof Error ? rollbackError.message : String(rollbackError),
        } satisfies ManualTrackerTransactionError;
      }
      throw error;
    }

    try {
      this.removeJournalIfPresent();
    } catch {
      // committed journal 可幂等重放
    }
  }

  private restore(currentData: Uint8Array | null, manualData: Uint8Array | null): void {
    try {
      validateVillageStoreBytes(currentData, '待恢复的当前村庄数据');
      this.current.restoreData(currentData);
      this.manual.restoreRawData(manualData);
    } catch (error) {
      if (
        typeof error === 'object' &&
        error !== null &&
        'kind' in error &&
        (error as { kind: string }).kind === 'corrupt'
      ) {
        throw {
          kind: 'journalCorrupt',
          message: error instanceof Error ? error.message : String(error),
        } satisfies ManualTrackerTransactionError;
      }
      throw {
        kind: 'rollbackFailed',
        message: error instanceof Error ? error.message : String(error),
      } satisfies ManualTrackerTransactionError;
    }
  }

  private writeJournal(journal: TrackerJournalV1): void {
    if (this.journalURL === null) {
      return;
    }
    try {
      mkdirSync(dirname(this.journalURL), { recursive: true });
      atomicWriteFile(this.journalURL, new TextEncoder().encode(JSON.stringify(journal)), {
        fault: this.fault,
      });
    } catch (error) {
      throw {
        kind: 'journalWriteFailed',
        message: error instanceof Error ? error.message : String(error),
      } satisfies ManualTrackerTransactionError;
    }
  }

  private removeJournalIfPresent(): void {
    if (this.journalURL === null || !existsSync(this.journalURL)) {
      return;
    }
    rmSync(this.journalURL);
  }
}

function validateManualBytes(data: Uint8Array | null, label: string): void {
  if (data === null) {
    return;
  }
  try {
    decodeManualTrackerEnvelopeWire(new TextDecoder().decode(data));
  } catch (error) {
    throw new Error(`${label}无效：${error instanceof Error ? error.message : String(error)}`);
  }
}

function encodeOptionalBase64(data: Uint8Array | null): string | null {
  return data === null ? null : bytesToBase64(data);
}

function decodeOptionalBase64(value: string | null): Uint8Array | null {
  return value === null ? null : base64ToBytes(value);
}
