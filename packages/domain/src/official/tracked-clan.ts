/** 手动跟踪部落档案（对齐 TrackedClanProfile.swift / §BE-1.5）。 */

import { isValidTag, normalizedTag } from '../tag/validator';

export type TrackedClanProfile = {
  readonly clanTag: string;
  readonly displayName: string | null;
  readonly createdAtMs: number;
};

export type TrackedClanStore = {
  readonly profiles: readonly TrackedClanProfile[];
};

export function createTrackedClanStore(
  profiles: readonly TrackedClanProfile[] = [],
): TrackedClanStore {
  return { profiles: [...profiles] };
}

/** 规范化部落 Tag；非法输入返回 undefined（对齐 ClanTagNormalizer）。 */
export function normalizeClanTag(raw: string | null | undefined): string | undefined {
  const trimmed = normalizedTag(raw);
  if (trimmed === undefined) {
    return undefined;
  }
  if (![...trimmed].every((character) => character.charCodeAt(0) <= 0x7f)) {
    return undefined;
  }
  const uppercased = trimmed.toUpperCase();
  if (!isValidTag(uppercased)) {
    return undefined;
  }
  return uppercased;
}

export function createTrackedClanProfile(input: {
  readonly clanTag: string;
  readonly displayName?: string | null;
  readonly createdAtMs: number;
}): TrackedClanProfile {
  const clanTag = normalizeClanTag(input.clanTag);
  if (clanTag === undefined) {
    throw new TypeError('TrackedClanProfile.clanTag 非法。');
  }
  const displayName =
    input.displayName === undefined || input.displayName === null
      ? null
      : input.displayName.trim().length === 0
        ? null
        : input.displayName.trim();
  return {
    clanTag,
    displayName,
    createdAtMs: input.createdAtMs,
  };
}

/** 按 tag 原位替换；不存在则追加到末尾（保持添加顺序）。 */
export function upsertTrackedClan(
  store: TrackedClanStore,
  profile: TrackedClanProfile,
): TrackedClanStore {
  const profiles = [...store.profiles];
  const index = profiles.findIndex((entry) => entry.clanTag === profile.clanTag);
  if (index >= 0) {
    profiles[index] = profile;
  } else {
    profiles.push(profile);
  }
  return createTrackedClanStore(profiles);
}

/** 删除指定 tag（幂等；入参会规范化）。 */
export function removeTrackedClan(store: TrackedClanStore, tag: string): TrackedClanStore {
  const normalized = normalizeClanTag(tag);
  if (normalized === undefined) {
    return store;
  }
  return createTrackedClanStore(store.profiles.filter((entry) => entry.clanTag !== normalized));
}

const MAX_STORE_ENTRIES = 10_000;

/**
 * 解码 TrackedClanStore wire（裸数组）。
 * 顶层非 array → throw（调用方 fail-open 归 []）；单条坏丢弃；maxEntries 截断。
 */
export function decodeTrackedClanStoreWire(value: unknown): TrackedClanStore {
  if (!Array.isArray(value)) {
    throw new TypeError('TrackedClanStore wire 必须是 array。');
  }
  const decoded: TrackedClanProfile[] = [];
  let guardCounter = 0;
  for (const entry of value) {
    guardCounter += 1;
    if (guardCounter > MAX_STORE_ENTRIES) {
      break;
    }
    try {
      decoded.push(decodeTrackedClanProfileWire(entry));
    } catch {
      // 单条容错
    }
  }
  return createTrackedClanStore(decoded);
}

export function encodeTrackedClanStoreWire(store: TrackedClanStore): unknown[] {
  return store.profiles.map(encodeTrackedClanProfileWire);
}

function encodeTrackedClanProfileWire(profile: TrackedClanProfile): unknown {
  return {
    clanTag: profile.clanTag,
    displayName: profile.displayName,
    createdAt: profile.createdAtMs,
  };
}

function decodeTrackedClanProfileWire(value: unknown): TrackedClanProfile {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new TypeError('TrackedClanProfile 必须是 object。');
  }
  const record = value as Record<string, unknown>;
  if (typeof record.clanTag !== 'string') {
    throw new TypeError('TrackedClanProfile.clanTag 必须是 string。');
  }
  const createdAtRaw = record.createdAt ?? record.createdAtMs;
  if (typeof createdAtRaw !== 'number' || !Number.isFinite(createdAtRaw)) {
    throw new TypeError('TrackedClanProfile.createdAt 必须是 number。');
  }
  const displayName =
    record.displayName === undefined || record.displayName === null
      ? null
      : typeof record.displayName === 'string'
        ? record.displayName
        : (() => {
            throw new TypeError('TrackedClanProfile.displayName 必须是 string | null。');
          })();
  return createTrackedClanProfile({
    clanTag: record.clanTag,
    displayName,
    createdAtMs: createdAtRaw,
  });
}
