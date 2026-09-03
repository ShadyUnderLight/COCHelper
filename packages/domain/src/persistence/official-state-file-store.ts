/**
 * OfficialStateStore ×4 + player-states 文件 repository（§BE-1.4 fail-open）。
 */

import type { WriteFaultInjector } from './fault';
import { readFailOpenJsonFile, writeFailOpenJsonFile } from './fail-open-file';
import {
  createOfficialStateStore,
  decodeOfficialStateStoreWire,
  encodeOfficialStateStoreWire,
  type OfficialStateStore,
} from '../official/official-state-store';
import {
  decodeClanAPIStateWire,
  decodeClanCapitalAPIStateWire,
  decodeClanWarAPIStateWire,
  decodeClanWarLogAPIStateWire,
  decodePlayerAPIStateWire,
  encodeClanAPIStateWire,
  encodeClanCapitalAPIStateWire,
  encodeClanWarAPIStateWire,
  encodeClanWarLogAPIStateWire,
  encodePlayerAPIStateWire,
} from '../official/endpoint-state-wire';
import type {
  ClanAPIState,
  ClanCapitalAPIState,
  ClanWarAPIState,
  ClanWarLogAPIState,
} from '../official/endpoint-state';
import type { OfficialAPIState } from '../official/player-state';

export type OfficialStateFileStoreOptions = {
  readonly fault?: WriteFaultInjector;
};

export class OfficialStateFileStore<State> {
  readonly fileURL: string | null;
  private readonly fault: WriteFaultInjector | undefined;
  private readonly decodeState: (value: unknown) => State;
  private readonly encodeState: (state: State) => unknown;

  constructor(
    fileURL: string | null,
    decodeState: (value: unknown) => State,
    encodeState: (state: State) => unknown,
    options: OfficialStateFileStoreOptions = {},
  ) {
    this.fileURL = fileURL;
    this.decodeState = decodeState;
    this.encodeState = encodeState;
    this.fault = options.fault;
  }

  /** missing / 顶层损坏 → 空 store（fail-open）。 */
  load(): OfficialStateStore<State> {
    const raw = readFailOpenJsonFile(this.fileURL);
    if (raw === null) {
      return createOfficialStateStore<State>();
    }
    try {
      return decodeOfficialStateStoreWire(raw, this.decodeState);
    } catch {
      return createOfficialStateStore<State>();
    }
  }

  save(store: OfficialStateStore<State>): void {
    const wire = encodeOfficialStateStoreWire(store, this.encodeState);
    writeFailOpenJsonFile(this.fileURL, wire, { fault: this.fault });
  }
}

export function createClanStateFileStore(
  fileURL: string | null,
  options?: OfficialStateFileStoreOptions,
): OfficialStateFileStore<ClanAPIState> {
  return new OfficialStateFileStore(
    fileURL,
    decodeClanAPIStateWire,
    encodeClanAPIStateWire,
    options,
  );
}

export function createClanWarStateFileStore(
  fileURL: string | null,
  options?: OfficialStateFileStoreOptions,
): OfficialStateFileStore<ClanWarAPIState> {
  return new OfficialStateFileStore(
    fileURL,
    decodeClanWarAPIStateWire,
    encodeClanWarAPIStateWire,
    options,
  );
}

export function createClanWarLogStateFileStore(
  fileURL: string | null,
  options?: OfficialStateFileStoreOptions,
): OfficialStateFileStore<ClanWarLogAPIState> {
  return new OfficialStateFileStore(
    fileURL,
    decodeClanWarLogAPIStateWire,
    encodeClanWarLogAPIStateWire,
    options,
  );
}

export function createClanCapitalStateFileStore(
  fileURL: string | null,
  options?: OfficialStateFileStoreOptions,
): OfficialStateFileStore<ClanCapitalAPIState> {
  return new OfficialStateFileStore(
    fileURL,
    decodeClanCapitalAPIStateWire,
    encodeClanCapitalAPIStateWire,
    options,
  );
}

/** 按 villageId 索引的玩家官方状态（villages-v1 已剥离 officialAPIState）。 */
export function createPlayerStateFileStore(
  fileURL: string | null,
  options?: OfficialStateFileStoreOptions,
): OfficialStateFileStore<OfficialAPIState> {
  return new OfficialStateFileStore(
    fileURL,
    decodePlayerAPIStateWire,
    encodePlayerAPIStateWire,
    options,
  );
}
