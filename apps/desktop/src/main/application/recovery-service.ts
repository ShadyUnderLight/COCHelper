/**
 * RecoveryService（#276-S5）：村庄恢复显式出口。
 * 对齐 §BE-1.1 / Swift AppModel：export / restore / reset / recoverJournal 均用户触发；
 * 启动从不自动隔离或重置。
 */

import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname } from 'node:path';

import type {
  RecoveryExportPayload,
  RecoveryRecoverJournalPayload,
  RecoveryResetPayload,
  RecoveryRestorePayload,
  RecoveryStatusPayload,
  VillageStoreStatusDto,
} from '@coc-helper/contracts';
import {
  assertFileSizeWithinLimit,
  atomicWriteFile,
  base64ToBytes,
  bytesToBase64,
  createVillageProfile,
  encodeVillageStoreBytes,
  isVillageStoreError,
  loadVillageStoreBytes,
  quarantinePendingJournals,
  removeQuarantinedJournal,
  reviveQuarantinedJournalIfNeeded,
  villageStoreStatusRequiresRecovery,
  type PersistenceBootstrapResult,
  type VillageProfile,
} from '@coc-helper/domain';
import { generateUuid } from '@coc-helper/wire';

import { AppServiceError, type AppAuthoritativeState } from './app-authoritative-state';
import { PersistentVillageStore } from './persistent-village-store';

export function hasPendingVillageJournals(
  paths: PersistenceBootstrapResult['paths'] | null | undefined,
): boolean {
  if (paths === undefined || paths === null) {
    return false;
  }
  return (
    existsSync(paths.snapshotImportJournal) ||
    existsSync(paths.manualTrackerJournal) ||
    existsSync(`${paths.snapshotImportJournal}.quarantined`) ||
    existsSync(`${paths.manualTrackerJournal}.quarantined`)
  );
}

export class RecoveryService {
  constructor(
    private readonly state: AppAuthoritativeState,
    private readonly persistence: PersistenceBootstrapResult | null,
  ) {}

  status(): RecoveryStatusPayload {
    const snapshot = this.state.snapshot();
    return {
      generation: snapshot.generation,
      sessionId: snapshot.sessionId,
      recoveryRequired: villageStoreStatusRequiresRecovery(snapshot.villageStatus),
      villageStatus: snapshot.villageStatus,
      villageError: snapshot.villageError,
      canWrite: snapshot.canWrite,
      hasPendingJournal: snapshot.hasPendingJournal,
      canExport: this.resolveExportBytes() !== null,
      canRestoreSavedCopy: this.readSavedRecoveryCopy() !== null,
      notice: snapshot.recoveryNotice,
    };
  }

  exportRaw(): RecoveryExportPayload {
    const bytes = this.resolveExportBytes();
    return {
      generation: this.state.getGeneration(),
      sessionId: this.state.getSessionId(),
      dataBase64: bytes === null ? null : bytesToBase64(bytes),
    };
  }

  restore(expectedGeneration: number, dataBase64: string): RecoveryRestorePayload {
    this.assertExpectedGeneration(expectedGeneration);
    this.assertRecoveryRequired();
    const candidate = decodeBase64Bytes(dataBase64);
    return this.restoreFromBytes(candidate, '村庄数据已恢复，原始恢复副本仍保留。');
  }

  restoreFromSavedCopy(expectedGeneration: number): RecoveryRestorePayload {
    this.assertExpectedGeneration(expectedGeneration);
    this.assertRecoveryRequired();
    const saved = this.readSavedRecoveryCopy();
    if (saved === null) {
      throw new AppServiceError('notFound', '没有找到保存的村庄恢复副本。');
    }
    return this.restoreFromBytes(saved, '已从保存的恢复副本恢复村庄数据。');
  }

  reset(expectedGeneration: number): RecoveryResetPayload {
    this.assertExpectedGeneration(expectedGeneration);
    this.assertRecoveryRequired();
    const persistence = this.requirePersistence();
    this.preserveRecoveryBytesBestEffort();
    quarantinePendingJournals([
      persistence.paths.snapshotImportJournal,
      persistence.paths.manualTrackerJournal,
    ]);

    const resetVillages = [createVillageProfile({ id: generateUuid(), name: '我的村庄' })];
    try {
      persistence.villages.reset(resetVillages);
    } catch (error) {
      throw mapPersistenceError(error, '重置写入失败');
    }

    this.installVillages(resetVillages, 'available', '村庄数据已重置；旧 bytes 已保存为恢复副本。');
    const snapshot = this.state.snapshot();
    return {
      generation: snapshot.generation,
      sessionId: snapshot.sessionId,
      villageStatus: snapshot.villageStatus,
      canWrite: snapshot.canWrite,
      notice: snapshot.recoveryNotice ?? '村庄数据已重置；旧 bytes 已保存为恢复副本。',
    };
  }

  recoverJournal(expectedGeneration: number): RecoveryRecoverJournalPayload {
    this.assertExpectedGeneration(expectedGeneration);
    this.assertRecoveryRequired();
    const persistence = this.requirePersistence();
    if (!hasPendingVillageJournals(persistence.paths)) {
      throw new AppServiceError('notFound', '没有找到待处理的事务 journal。');
    }

    this.preserveRecoveryBytesBestEffort();

    try {
      reviveQuarantinedJournalIfNeeded(persistence.paths.snapshotImportJournal);
      persistence.importTransaction.recoverIfNeeded();
      reviveQuarantinedJournalIfNeeded(persistence.paths.manualTrackerJournal);
      persistence.manualTransaction.recoverIfNeeded();
      removeQuarantinedJournal(persistence.paths.snapshotImportJournal);
      removeQuarantinedJournal(persistence.paths.manualTrackerJournal);
    } catch (error) {
      const message = formatError(error);
      this.state.noteRecoveryFailure(
        `事务 journal 恢复失败；原始数据和未处理 journal 仍保留。`,
        message,
      );
      const snapshot = this.state.snapshot();
      return {
        generation: snapshot.generation,
        sessionId: snapshot.sessionId,
        villageStatus: snapshot.villageStatus,
        canWrite: false,
        notice: snapshot.recoveryNotice ?? '事务 journal 恢复失败。',
      };
    }

    const loaded = loadVillageStoreBytes(persistence.villages.readData());
    if (
      loaded.kind === 'corrupt' ||
      loaded.kind === 'unsupportedSchema' ||
      loaded.kind === 'unavailable'
    ) {
      const message =
        loaded.kind === 'corrupt'
          ? `事务记录恢复后当前村庄数据仍无法解码：\n${loaded.message}`
          : loaded.kind === 'unsupportedSchema'
            ? `事务记录恢复后检测到未来村庄存储版本 ${String(loaded.schemaVersion)}。`
            : `事务记录恢复后村庄存储仍不可用：${loaded.message}`;
      this.state.noteRecoveryFailure(message, message);
      const snapshot = this.state.snapshot();
      return {
        generation: snapshot.generation,
        sessionId: snapshot.sessionId,
        villageStatus: snapshot.villageStatus,
        canWrite: false,
        notice: snapshot.recoveryNotice ?? message,
      };
    }

    let villages: VillageProfile[];
    let status: VillageStoreStatusDto;
    if (loaded.kind === 'missing' || loaded.villages.length === 0) {
      villages = [createVillageProfile({ id: generateUuid(), name: '我的村庄' })];
      status = loaded.kind === 'missing' ? 'missing' : 'empty';
      persistence.villages.writeData(encodeVillageStoreBytes(villages));
    } else {
      villages = [...loaded.villages];
      status = 'available';
    }

    this.installVillages(
      villages,
      status,
      '事务 journal 已恢复；prepared 已回滚，committed 已重放。',
    );
    const snapshot = this.state.snapshot();
    return {
      generation: snapshot.generation,
      sessionId: snapshot.sessionId,
      villageStatus: snapshot.villageStatus,
      canWrite: snapshot.canWrite,
      notice: snapshot.recoveryNotice ?? '事务 journal 已恢复。',
    };
  }

  private restoreFromBytes(candidate: Uint8Array, notice: string): RecoveryRestorePayload {
    const persistence = this.requirePersistence();
    const loaded = loadVillageStoreBytes(candidate);
    if (loaded.kind !== 'loaded') {
      throw new AppServiceError('validation', '恢复文件不是合法的村庄存储，未写入当前数据。');
    }

    this.preserveRecoveryBytesBestEffort();
    quarantinePendingJournals([
      persistence.paths.snapshotImportJournal,
      persistence.paths.manualTrackerJournal,
    ]);

    const preservesRawData = loaded.villages.length > 0;
    const villages =
      loaded.villages.length === 0
        ? [createVillageProfile({ id: generateUuid(), name: '我的村庄' })]
        : [...loaded.villages];
    const status: VillageStoreStatusDto = loaded.villages.length === 0 ? 'empty' : 'available';

    try {
      if (preservesRawData) {
        persistence.villages.writeData(candidate);
      } else {
        persistence.villages.writeData(encodeVillageStoreBytes(villages));
      }
    } catch (error) {
      throw mapPersistenceError(error, '恢复写入失败');
    }

    this.installVillages(villages, status, notice);
    const snapshot = this.state.snapshot();
    return {
      generation: snapshot.generation,
      sessionId: snapshot.sessionId,
      villageStatus: snapshot.villageStatus,
      canWrite: snapshot.canWrite,
      notice: snapshot.recoveryNotice ?? notice,
    };
  }

  private installVillages(
    villages: readonly VillageProfile[],
    villageStatus: VillageStoreStatusDto,
    notice: string,
  ): void {
    const persistence = this.requirePersistence();
    const villageStore = new PersistentVillageStore({
      villages: persistence.villages,
      selection: persistence.selection,
      initialVillages: villages,
      initialSelectedVillageId: resolveSelected(villages, persistence.selectedVillageId),
    });
    this.state.installAvailableState({
      villageStore,
      villageStatus,
      villageError: null,
      notice,
    });
  }

  private assertExpectedGeneration(expectedGeneration: number): void {
    if (expectedGeneration !== this.state.getGeneration()) {
      throw new AppServiceError('conflict', 'expectedGeneration 与当前权威 generation 不一致。');
    }
  }

  private assertRecoveryRequired(): void {
    const status = this.state.snapshot().villageStatus;
    if (!villageStoreStatusRequiresRecovery(status)) {
      throw new AppServiceError('validation', '当前村庄数据无需恢复。');
    }
  }

  private requirePersistence(): PersistenceBootstrapResult {
    if (this.persistence === null) {
      throw new AppServiceError('unavailable', '持久化未就绪，无法执行恢复。');
    }
    return this.persistence;
  }

  private resolveExportBytes(): Uint8Array | null {
    if (this.persistence === null) {
      return null;
    }
    if (this.persistence.villageRecoveryData !== null) {
      return this.persistence.villageRecoveryData;
    }
    try {
      return this.persistence.villages.readData();
    } catch {
      return null;
    }
  }

  private readSavedRecoveryCopy(): Uint8Array | null {
    if (this.persistence === null) {
      return null;
    }
    const path = this.persistence.paths.villagesRecovery;
    if (!existsSync(path)) {
      return null;
    }
    try {
      assertFileSizeWithinLimit(path);
      return readFileSync(path);
    } catch {
      return null;
    }
  }

  private preserveRecoveryBytesBestEffort(): void {
    if (this.persistence === null || this.persistence.villageRecoveryData === null) {
      return;
    }
    const path = this.persistence.paths.villagesRecovery;
    try {
      mkdirSync(dirname(path), { recursive: true });
      atomicWriteFile(path, this.persistence.villageRecoveryData);
    } catch {
      // best-effort：恢复主路径不因副本备份失败而中断。
    }
  }
}

function resolveSelected(
  villages: readonly VillageProfile[],
  preferred: string | null,
): string | null {
  if (preferred !== null && villages.some((village) => village.id === preferred)) {
    return preferred;
  }
  return villages[0]?.id ?? null;
}

function decodeBase64Bytes(dataBase64: string): Uint8Array {
  try {
    const bytes = base64ToBytes(dataBase64);
    if (bytes.length === 0) {
      throw new AppServiceError('validation', '恢复数据为空。');
    }
    return bytes;
  } catch (error) {
    if (error instanceof AppServiceError) {
      throw error;
    }
    throw new AppServiceError('validation', '恢复数据不是合法的 base64。');
  }
}

function mapPersistenceError(error: unknown, prefix: string): AppServiceError {
  if (isVillageStoreError(error)) {
    const detail =
      error.kind === 'unsupportedSchema'
        ? `unsupportedSchema:${String(error.version)}`
        : error.message;
    return new AppServiceError('unavailable', `${prefix}：${detail}`);
  }
  return new AppServiceError('unavailable', `${prefix}：${formatError(error)}`);
}

function formatError(error: unknown): string {
  if (isVillageStoreError(error)) {
    return error.kind === 'unsupportedSchema'
      ? `unsupportedSchema:${String(error.version)}`
      : error.message;
  }
  return error instanceof Error ? error.message : String(error);
}
