/** 官方端点状态持久化容器（对齐 OfficialStateStore.swift）。 */

export type OfficialStateStore<State> = {
  readonly states: Readonly<Record<string, State>>;
};

export function createOfficialStateStore<State>(
  states: Readonly<Record<string, State>> = {},
): OfficialStateStore<State> {
  return { states };
}

export function mergeOfficialStateStore<State>(
  store: OfficialStateStore<State>,
  refreshed: Readonly<Record<string, State>>,
): OfficialStateStore<State> {
  return createOfficialStateStore({ ...store.states, ...refreshed });
}

/** 解码与写入共用的条目上限；超限不得静默写出后再在 load 时截断。 */
export const OFFICIAL_STATE_STORE_MAX_ENTRIES = 10_000;

const MAX_STORE_ENTRIES = OFFICIAL_STATE_STORE_MAX_ENTRIES;

function skipJsonValue(value: unknown): void {
  if (value === null || typeof value !== 'object') {
    return;
  }
  if (Array.isArray(value)) {
    for (const entry of value) {
      skipJsonValue(entry);
    }
    return;
  }
  for (const entry of Object.values(value as Record<string, unknown>)) {
    skipJsonValue(entry);
  }
}

export function decodeOfficialStateStoreWire<State>(
  value: unknown,
  decodeState: (entry: unknown) => State,
): OfficialStateStore<State> {
  if (!Array.isArray(value)) {
    throw new TypeError('OfficialStateStore wire 必须是 array。');
  }
  const decoded: Record<string, State> = Object.create(null);
  let guardCounter = 0;
  for (const entry of value) {
    guardCounter += 1;
    if (guardCounter > MAX_STORE_ENTRIES) {
      break;
    }
    if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
      continue;
    }
    const keys = Object.keys(entry);
    if (keys.length === 0) {
      continue;
    }
    const tag = keys[0]!;
    try {
      decoded[tag] = decodeState((entry as Record<string, unknown>)[tag]);
    } catch {
      skipJsonValue(entry);
    }
  }
  return createOfficialStateStore(decoded);
}

export function encodeOfficialStateStoreWire<State>(
  store: OfficialStateStore<State>,
  encodeState: (state: State) => unknown,
): unknown[] {
  return Object.keys(store.states)
    .sort()
    .map((tag) => ({ [tag]: encodeState(store.states[tag]!) }));
}

export type ClanStateStore = OfficialStateStore<import('./endpoint-state').ClanAPIState>;
export type ClanWarStateStore = OfficialStateStore<import('./endpoint-state').ClanWarAPIState>;
export type ClanWarLogStateStore = OfficialStateStore<
  import('./endpoint-state').ClanWarLogAPIState
>;
export type ClanCapitalStateStore = OfficialStateStore<
  import('./endpoint-state').ClanCapitalAPIState
>;
