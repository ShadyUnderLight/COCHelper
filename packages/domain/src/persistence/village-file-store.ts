import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';

import type { VillageProfile } from '../import/types';
import { atomicWriteFile } from './atomic-write';
import { PERSISTENCE_FILE_NAMES, resolveElectronDataRoot } from './data-root';
import type { WriteFaultInjector } from './fault';
import { assertFileSizeWithinLimit, isPersistenceTooLargeError } from './limits';
import {
  encodeVillageStoreBytes,
  loadVillageStoreBytes,
  isVillageStoreError,
  type VillageStoreError,
  type VillageStoreLoadResult,
  validateVillageStoreBytes,
} from './village-codec';

export type CurrentVillagePersistence = {
  readData(): Uint8Array | null;
  writeData(data: Uint8Array): void;
  restoreData(data: Uint8Array | null): void;
};

export type VillageFileStoreOptions = {
  readonly fault?: WriteFaultInjector;
};

export function defaultVillagesFileURL(homeDirectory?: string): string | null {
  const root = resolveElectronDataRoot(homeDirectory);
  return root === null ? null : join(root, PERSISTENCE_FILE_NAMES.villages);
}

export class VillageFileStore implements CurrentVillagePersistence {
  readonly fileURL: string | null;
  readonly recoveryFileURL: string | null;
  private readonly fault: WriteFaultInjector | undefined;

  constructor(fileURL: string | null, options: VillageFileStoreOptions = {}) {
    this.fileURL = fileURL;
    this.recoveryFileURL =
      fileURL === null ? null : join(dirname(fileURL), PERSISTENCE_FILE_NAMES.villagesRecovery);
    this.fault = options.fault;
  }

  load(): VillageStoreLoadResult {
    return loadVillageStoreBytes(this.readData());
  }

  save(villages: readonly VillageProfile[]): void {
    try {
      validateVillageStoreBytes(encodeVillageStoreBytes(villages), '候选村庄数据');
      this.writeData(encodeVillageStoreBytes(villages));
    } catch (error) {
      if (isVillageStoreError(error)) {
        throw error;
      }
      throw {
        kind: 'writeFailed',
        message: error instanceof Error ? error.message : String(error),
      } satisfies VillageStoreError;
    }
  }

  readData(): Uint8Array | null {
    if (this.fileURL === null) {
      throw {
        kind: 'unavailable',
        message: '没有可用的村庄文件路径。',
      } satisfies VillageStoreError;
    }
    if (!existsSync(this.fileURL)) {
      return null;
    }
    try {
      assertFileSizeWithinLimit(this.fileURL);
      return readFileSync(this.fileURL);
    } catch (error) {
      if (isVillageStoreError(error)) {
        throw error;
      }
      if (isPersistenceTooLargeError(error)) {
        throw {
          kind: 'unavailable',
          message: error.message,
        } satisfies VillageStoreError;
      }
      throw {
        kind: 'unavailable',
        message: error instanceof Error ? error.message : String(error),
      } satisfies VillageStoreError;
    }
  }

  writeData(data: Uint8Array): void {
    if (this.fileURL === null) {
      throw {
        kind: 'unavailable',
        message: '没有可用的村庄文件路径。',
      } satisfies VillageStoreError;
    }
    try {
      mkdirSync(dirname(this.fileURL), { recursive: true });
      atomicWriteFile(this.fileURL, data, { fault: this.fault });
      const written = readFileSync(this.fileURL);
      if (written.length !== data.length || !written.every((byte, index) => byte === data[index])) {
        throw {
          kind: 'writeFailed',
          message: '写入后读回的村庄数据与候选数据不一致。',
        } satisfies VillageStoreError;
      }
    } catch (error) {
      if (isVillageStoreError(error)) {
        throw error;
      }
      throw {
        kind: 'writeFailed',
        message: error instanceof Error ? error.message : String(error),
      } satisfies VillageStoreError;
    }
  }

  restoreData(data: Uint8Array | null): void {
    if (this.fileURL === null) {
      throw {
        kind: 'unavailable',
        message: '没有可用的村庄文件路径。',
      } satisfies VillageStoreError;
    }
    try {
      if (data !== null) {
        mkdirSync(dirname(this.fileURL), { recursive: true });
        atomicWriteFile(this.fileURL, data, { fault: this.fault });
        const written = readFileSync(this.fileURL);
        if (
          written.length !== data.length ||
          !written.every((byte, index) => byte === data[index])
        ) {
          throw {
            kind: 'writeFailed',
            message: '恢复后读回的村庄数据与原始数据不一致。',
          } satisfies VillageStoreError;
        }
      } else if (existsSync(this.fileURL)) {
        rmSync(this.fileURL);
        if (existsSync(this.fileURL)) {
          throw {
            kind: 'writeFailed',
            message: '删除村庄数据后仍能读到旧数据。',
          } satisfies VillageStoreError;
        }
      }
    } catch (error) {
      if (isVillageStoreError(error)) {
        throw error;
      }
      throw {
        kind: 'writeFailed',
        message: `回滚村庄文件失败：${error instanceof Error ? error.message : String(error)}`,
      } satisfies VillageStoreError;
    }
  }

  exportRawData(): Uint8Array | null {
    return this.readData();
  }

  /** 显式恢复：非法输入绝不覆盖现有 bytes。 */
  restoreFromExport(candidate: Uint8Array): void {
    const result = loadVillageStoreBytes(candidate);
    if (result.kind !== 'loaded') {
      throw {
        kind: 'invalid',
        message: '恢复副本不是合法的村庄存储。',
      } satisfies VillageStoreError;
    }
    this.writeData(candidate);
  }

  /** 显式重置：旧 bytes 先写入 recovery 文件。 */
  reset(emptyVillages: readonly VillageProfile[]): void {
    if (this.recoveryFileURL === null || this.fileURL === null) {
      throw {
        kind: 'unavailable',
        message: '没有可用的村庄恢复路径。',
      } satisfies VillageStoreError;
    }
    const previous = this.readData();
    if (previous !== null) {
      atomicWriteFile(this.recoveryFileURL, previous, { fault: this.fault });
    }
    this.writeData(encodeVillageStoreBytes(emptyVillages));
  }
}
