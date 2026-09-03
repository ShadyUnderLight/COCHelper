/** TrackedClanStore 文件 repository（§BE-1.5 fail-open）。 */

import type { WriteFaultInjector } from './fault';
import {
  assertFailOpenEntryCount,
  readFailOpenJsonFile,
  writeFailOpenJsonFile,
} from './fail-open-file';
import {
  createTrackedClanStore,
  decodeTrackedClanStoreWire,
  encodeTrackedClanStoreWire,
  type TrackedClanStore,
} from '../official/tracked-clan';

export type TrackedClanFileStoreOptions = {
  readonly fault?: WriteFaultInjector;
};

export class TrackedClanFileStore {
  readonly fileURL: string | null;
  private readonly fault: WriteFaultInjector | undefined;

  constructor(fileURL: string | null, options: TrackedClanFileStoreOptions = {}) {
    this.fileURL = fileURL;
    this.fault = options.fault;
  }

  /** missing / 顶层损坏 → []。 */
  load(): TrackedClanStore {
    const raw = readFailOpenJsonFile(this.fileURL);
    if (raw === null) {
      return createTrackedClanStore();
    }
    try {
      return decodeTrackedClanStoreWire(raw);
    } catch {
      return createTrackedClanStore();
    }
  }

  save(store: TrackedClanStore): void {
    assertFailOpenEntryCount(store.profiles.length);
    writeFailOpenJsonFile(this.fileURL, encodeTrackedClanStoreWire(store), {
      fault: this.fault,
    });
  }
}
