/**
 * OfficialEndpointState / OfficialAPIState ↔ Electron 落盘 wire。
 * 时间字段使用 Unix ms（fetchedAt / lastAttemptAt）；新根不做旧 UserDefaults 双读。
 */

import { asRecord, optionalInt, optionalString } from './json-decode';
import { decodeOfficialClanSnapshot, type OfficialClanSnapshot } from './models/clan';
import { decodeOfficialClanWarSnapshot, type OfficialClanWarSnapshot } from './models/clan-war';
import {
  decodeOfficialCapitalRaidSeason,
  type OfficialCapitalRaidPage,
  type OfficialCapitalRaidSeason,
} from './models/capital-raid';
import { decodeOfficialPlayerSnapshot, type OfficialPlayerSnapshot } from './models/player';
import {
  decodeOfficialWarLogEntry,
  type OfficialWarLogEntry,
  type OfficialWarLogPage,
} from './models/war-log';
import { createOfficialPaginatedPage } from './models/paginated-page';
import {
  createOfficialEndpointState,
  type ClanAPIState,
  type ClanCapitalAPIState,
  type ClanWarAPIState,
  type ClanWarLogAPIState,
  type OfficialEndpointState,
} from './endpoint-state';
import { createOfficialAPIState, type OfficialAPIState } from './player-state';
import type { OfficialAPIRequestStatus, OfficialEndpointFailureKind } from './types';

const REQUEST_STATUSES: readonly OfficialAPIRequestStatus[] = [
  'never',
  'loading',
  'success',
  'failed',
  'skipped',
];
const FAILURE_KINDS: readonly OfficialEndpointFailureKind[] = [
  'missingCredentials',
  'unauthorized',
  'accessDenied',
  'notFound',
  'rateLimited',
  'serverError',
  'timeout',
  'network',
  'malformedResponse',
  'cancelled',
];
const REQUEST_STATUS_SET = new Set<string>(REQUEST_STATUSES);
const FAILURE_KIND_SET = new Set<string>(FAILURE_KINDS);

export function encodeClanAPIStateWire(state: ClanAPIState): unknown {
  return encodeEndpointStateWire(state, (snapshot) => snapshot);
}

export function decodeClanAPIStateWire(value: unknown): ClanAPIState {
  return decodeEndpointStateWire(value, decodePersistedClanSnapshot);
}

export function encodeClanWarAPIStateWire(state: ClanWarAPIState): unknown {
  return encodeEndpointStateWire(state, (snapshot) => snapshot);
}

export function decodeClanWarAPIStateWire(value: unknown): ClanWarAPIState {
  return decodeEndpointStateWire(value, decodePersistedClanWarSnapshot);
}

export function encodeClanWarLogAPIStateWire(state: ClanWarLogAPIState): unknown {
  return encodeEndpointStateWire(state, encodeWarLogPageWire);
}

export function decodeClanWarLogAPIStateWire(value: unknown): ClanWarLogAPIState {
  return decodeEndpointStateWire(value, decodePersistedWarLogPage);
}

export function encodeClanCapitalAPIStateWire(state: ClanCapitalAPIState): unknown {
  return encodeEndpointStateWire(state, encodeCapitalRaidPageWire);
}

export function decodeClanCapitalAPIStateWire(value: unknown): ClanCapitalAPIState {
  return decodeEndpointStateWire(value, decodePersistedCapitalRaidPage);
}

export function encodePlayerAPIStateWire(state: OfficialAPIState): unknown {
  const wire: Record<string, unknown> = {
    status: state.status,
    parserVersion: state.parserVersion,
    unrecognizedKeys: [...state.unrecognizedKeys],
  };
  if (state.playerTag !== undefined) {
    wire.playerTag = state.playerTag;
  }
  if (state.fetchedAtMs !== undefined) {
    wire.fetchedAt = state.fetchedAtMs;
  }
  if (state.lastAttemptAtMs !== undefined) {
    wire.lastAttemptAt = state.lastAttemptAtMs;
  }
  if (state.lastErrorReason !== undefined) {
    wire.lastErrorReason = state.lastErrorReason;
  }
  if (state.lastHTTPStatus !== undefined) {
    wire.lastHTTPStatus = state.lastHTTPStatus;
  }
  if (state.lastGood !== undefined) {
    wire.lastGood = state.lastGood;
  }
  return wire;
}

export function decodePlayerAPIStateWire(value: unknown): OfficialAPIState {
  const record = asRecord(value, 'OfficialAPIState');
  const status = decodeRequestStatus(record.status);
  const parserVersion = optionalString(record.parserVersion);
  if (parserVersion === undefined) {
    throw new TypeError('OfficialAPIState.parserVersion 必填。');
  }
  return createOfficialAPIState({
    status,
    playerTag: optionalString(record.playerTag),
    fetchedAtMs: optionalInt(record.fetchedAt ?? record.fetchedAtMs),
    lastAttemptAtMs: optionalInt(record.lastAttemptAt ?? record.lastAttemptAtMs),
    lastErrorReason: optionalString(record.lastErrorReason),
    lastHTTPStatus: optionalInt(record.lastHTTPStatus),
    parserVersion,
    lastGood:
      record.lastGood === undefined || record.lastGood === null
        ? undefined
        : decodePersistedPlayerSnapshot(record.lastGood),
    unrecognizedKeys: decodeStringArray(record.unrecognizedKeys),
  });
}

function encodeEndpointStateWire<Snapshot>(
  state: OfficialEndpointState<Snapshot>,
  encodeSnapshot: (snapshot: Snapshot) => unknown,
): unknown {
  const wire: Record<string, unknown> = {
    status: state.status,
    parserVersion: state.parserVersion,
    unrecognizedKeys: [...state.unrecognizedKeys],
  };
  if (state.clanTag !== undefined) {
    wire.clanTag = state.clanTag;
  }
  if (state.fetchedAtMs !== undefined) {
    wire.fetchedAt = state.fetchedAtMs;
  }
  if (state.lastAttemptAtMs !== undefined) {
    wire.lastAttemptAt = state.lastAttemptAtMs;
  }
  if (state.lastErrorReason !== undefined) {
    wire.lastErrorReason = state.lastErrorReason;
  }
  if (state.lastHTTPStatus !== undefined) {
    wire.lastHTTPStatus = state.lastHTTPStatus;
  }
  if (state.failureKind !== undefined) {
    wire.failureKind = state.failureKind;
  }
  if (state.lastGood !== undefined) {
    wire.lastGood = encodeSnapshot(state.lastGood);
  }
  return wire;
}

function decodeEndpointStateWire<Snapshot>(
  value: unknown,
  decodeSnapshot: (value: unknown) => Snapshot,
): OfficialEndpointState<Snapshot> {
  const record = asRecord(value, 'OfficialEndpointState');
  const status = decodeRequestStatus(record.status);
  const parserVersion = optionalString(record.parserVersion);
  if (parserVersion === undefined) {
    throw new TypeError('OfficialEndpointState.parserVersion 必填。');
  }
  return createOfficialEndpointState({
    status,
    clanTag: optionalString(record.clanTag),
    fetchedAtMs: optionalInt(record.fetchedAt ?? record.fetchedAtMs),
    lastAttemptAtMs: optionalInt(record.lastAttemptAt ?? record.lastAttemptAtMs),
    lastErrorReason: optionalString(record.lastErrorReason),
    lastHTTPStatus: optionalInt(record.lastHTTPStatus),
    failureKind: decodeFailureKind(record.failureKind),
    parserVersion,
    lastGood:
      record.lastGood === undefined || record.lastGood === null
        ? undefined
        : decodeSnapshot(record.lastGood),
    unrecognizedKeys: decodeStringArray(record.unrecognizedKeys),
  });
}

function decodeRequestStatus(value: unknown): OfficialAPIRequestStatus {
  if (typeof value !== 'string' || !REQUEST_STATUS_SET.has(value)) {
    throw new TypeError('status 非法。');
  }
  return value as OfficialAPIRequestStatus;
}

function decodeFailureKind(value: unknown): OfficialEndpointFailureKind | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== 'string' || !FAILURE_KIND_SET.has(value)) {
    throw new TypeError('failureKind 非法。');
  }
  return value as OfficialEndpointFailureKind;
}

function decodeStringArray(value: unknown): readonly string[] {
  if (value === undefined || value === null) {
    return [];
  }
  if (!Array.isArray(value) || !value.every((entry) => typeof entry === 'string')) {
    throw new TypeError('unrecognizedKeys 必须是 string[]。');
  }
  return value;
}

function decodePersistedClanSnapshot(value: unknown): OfficialClanSnapshot {
  return decodeWithPreservedUnrecognizedKeys(value, decodeOfficialClanSnapshot);
}

function decodePersistedClanWarSnapshot(value: unknown): OfficialClanWarSnapshot {
  return decodeWithPreservedUnrecognizedKeys(value, decodeOfficialClanWarSnapshot);
}

function decodePersistedPlayerSnapshot(value: unknown): OfficialPlayerSnapshot {
  return decodeWithPreservedUnrecognizedKeys(value, decodeOfficialPlayerSnapshot);
}

function decodeWithPreservedUnrecognizedKeys<
  T extends { readonly unrecognizedKeys: readonly string[] },
>(value: unknown, decode: (value: unknown) => T): T {
  const record = asRecord(value, 'persistedSnapshot');
  const persisted = record.unrecognizedKeys;
  const without = { ...record };
  delete without.unrecognizedKeys;
  const decoded = decode(without);
  if (Array.isArray(persisted) && persisted.every((entry) => typeof entry === 'string')) {
    return { ...decoded, unrecognizedKeys: persisted };
  }
  return decoded;
}

function encodeWarLogPageWire(page: OfficialWarLogPage): unknown {
  return {
    page: {
      items: page.page.items,
      before: page.page.before,
      after: page.page.after,
    },
    unrecognizedKeys: [...page.unrecognizedKeys],
  };
}

function decodePersistedWarLogPage(value: unknown): OfficialWarLogPage {
  const record = asRecord(value, 'OfficialWarLogPage');
  if (record.page !== undefined && record.page !== null) {
    const page = asRecord(record.page, 'page');
    if (!Array.isArray(page.items)) {
      throw new TypeError('OfficialWarLogPage.page.items 必填。');
    }
    const items: OfficialWarLogEntry[] = page.items.map((entry) =>
      decodeOfficialWarLogEntry(entry),
    );
    return {
      page: createOfficialPaginatedPage(
        items,
        optionalString(page.before),
        optionalString(page.after),
      ),
      unrecognizedKeys: decodeStringArray(record.unrecognizedKeys),
    };
  }
  // API 形状 fallback：{ items, paging? }
  const itemsRaw = record.items;
  if (!Array.isArray(itemsRaw)) {
    throw new TypeError('OfficialWarLogPage 无法解码。');
  }
  return {
    page: createOfficialPaginatedPage(
      itemsRaw.map((entry) => decodeOfficialWarLogEntry(entry)),
      undefined,
      undefined,
    ),
    unrecognizedKeys: [],
  };
}

function encodeCapitalRaidPageWire(page: OfficialCapitalRaidPage): unknown {
  return {
    page: {
      items: page.page.items,
      before: page.page.before,
      after: page.page.after,
    },
    unrecognizedKeys: [...page.unrecognizedKeys],
  };
}

function decodePersistedCapitalRaidPage(value: unknown): OfficialCapitalRaidPage {
  const record = asRecord(value, 'OfficialCapitalRaidPage');
  if (record.page === undefined || record.page === null) {
    throw new TypeError('OfficialCapitalRaidPage.page 必填。');
  }
  const page = asRecord(record.page, 'page');
  if (!Array.isArray(page.items)) {
    throw new TypeError('OfficialCapitalRaidPage.page.items 必填。');
  }
  const items = page.items.map(
    (entry) => decodeOfficialCapitalRaidSeason(entry) as OfficialCapitalRaidSeason,
  );
  return {
    page: createOfficialPaginatedPage(
      items,
      optionalString(page.before),
      optionalString(page.after),
    ),
    unrecognizedKeys: decodeStringArray(record.unrecognizedKeys),
  };
}
