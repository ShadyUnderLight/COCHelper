/** 当前选中村庄落盘（soft fail-open；不进 import/manual journal）。 */

import type { WriteFaultInjector } from './fault';
import { readFailOpenJsonFile, writeFailOpenJsonFile } from './fail-open-file';

export type SelectionFileV1 = {
  readonly selectedVillageId: string | null;
};

export type SelectionFileStoreOptions = {
  readonly fault?: WriteFaultInjector;
};

export class SelectionFileStore {
  readonly fileURL: string | null;
  private readonly fault: WriteFaultInjector | undefined;

  constructor(fileURL: string | null, options: SelectionFileStoreOptions = {}) {
    this.fileURL = fileURL;
    this.fault = options.fault;
  }

  /** missing / corrupt → null（调用方回落列表第一项）。 */
  load(): string | null {
    const raw = readFailOpenJsonFile(this.fileURL);
    if (raw === null) {
      return null;
    }
    if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
      return null;
    }
    const id = (raw as { selectedVillageId?: unknown }).selectedVillageId;
    if (id === null) {
      return null;
    }
    if (typeof id !== 'string' || id.length === 0) {
      return null;
    }
    return id;
  }

  save(selectedVillageId: string | null): void {
    const payload: SelectionFileV1 = { selectedVillageId };
    writeFailOpenJsonFile(this.fileURL, payload, { fault: this.fault });
  }
}

/** 在当前 villages 中解析 selection；非法 id → 第一项。 */
export function resolveSelectedVillageId(
  villageIds: readonly string[],
  persistedId: string | null,
): string | null {
  if (villageIds.length === 0) {
    return null;
  }
  if (persistedId !== null && villageIds.includes(persistedId)) {
    return persistedId;
  }
  return villageIds[0]!;
}
