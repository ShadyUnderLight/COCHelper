/** 官方 API 共享 cache 的 orphan 保留策略（对齐 Issue #253 / #274）。 */

export type OrphanCacheEndpointKind = 'clan' | 'player';

export type OrphanCacheDisposition = 'retain' | 'orphan' | 'purgeEligible';

/** 默认 orphan TTL：30 天（仅 policy 纯函数默认；持久化/TTL 配置由 E3-01 接线）。 */
export const DEFAULT_ORPHAN_CACHE_TTL_MS = 30 * 24 * 3600 * 1000;

export function isOfficialCacheTagReferenced(input: {
  readonly tag: string;
  readonly villageClanTags: readonly string[];
  readonly trackedClanTags: readonly string[];
  readonly playerTags?: readonly string[];
  readonly endpointKind: OrphanCacheEndpointKind;
}): boolean {
  if (input.endpointKind === 'player') {
    return input.playerTags?.includes(input.tag) ?? false;
  }
  return input.villageClanTags.includes(input.tag) || input.trackedClanTags.includes(input.tag);
}

/**
 * 判定单个 cache tag 的保留语义：
 * - retain：仍被村庄/跟踪部落/玩家引用
 * - orphan：已无引用，但尚未达到 TTL（含刚进入 orphan、未记录 orphanSince 的宽限期）
 * - purgeEligible：已无引用且 orphanSince + TTL 到期
 */
export function classifyOrphanCacheTag(input: {
  readonly tag: string;
  readonly villageClanTags: readonly string[];
  readonly trackedClanTags: readonly string[];
  readonly playerTags?: readonly string[];
  readonly endpointKind: OrphanCacheEndpointKind;
  readonly orphanSinceMs?: number | undefined;
  readonly nowMs: number;
  readonly orphanTtlMs?: number;
}): OrphanCacheDisposition {
  if (
    isOfficialCacheTagReferenced({
      tag: input.tag,
      villageClanTags: input.villageClanTags,
      trackedClanTags: input.trackedClanTags,
      playerTags: input.playerTags,
      endpointKind: input.endpointKind,
    })
  ) {
    return 'retain';
  }

  const ttl = input.orphanTtlMs ?? DEFAULT_ORPHAN_CACHE_TTL_MS;
  // fail-closed：无效 TTL 不借配置错误获得 purge 资格（对齐 CacheRetentionPolicy no-op 语义）。
  if (!Number.isFinite(ttl) || ttl <= 0) {
    return 'orphan';
  }
  if (input.orphanSinceMs === undefined) {
    return 'orphan';
  }
  const sinceMs = input.orphanSinceMs;
  if (!Number.isFinite(sinceMs) || sinceMs < 0) {
    return 'orphan';
  }
  return input.nowMs - sinceMs >= ttl ? 'purgeEligible' : 'orphan';
}

/** 从 store tag 集合中筛出可 purge 的条目（fail-closed：仍被引用的一律排除）。 */
export function purgeEligibleCacheTags(input: {
  readonly cacheTags: readonly string[];
  readonly villageClanTags: readonly string[];
  readonly trackedClanTags: readonly string[];
  readonly playerTags?: readonly string[];
  readonly endpointKind: OrphanCacheEndpointKind;
  readonly orphanSinceByTag: Readonly<Record<string, number>>;
  readonly nowMs: number;
  readonly orphanTtlMs?: number;
}): readonly string[] {
  return input.cacheTags.filter(
    (tag) =>
      classifyOrphanCacheTag({
        tag,
        villageClanTags: input.villageClanTags,
        trackedClanTags: input.trackedClanTags,
        playerTags: input.playerTags,
        endpointKind: input.endpointKind,
        orphanSinceMs: input.orphanSinceByTag[tag],
        nowMs: input.nowMs,
        orphanTtlMs: input.orphanTtlMs,
      }) === 'purgeEligible',
  );
}

/** 移除已重新获得引用的 tag 的 orphan 时间戳（引用恢复 → retain）。 */
export function pruneOrphanTimestamps(input: {
  readonly orphanSinceByTag: Readonly<Record<string, number>>;
  readonly retainedTags: ReadonlySet<string>;
}): Record<string, number> {
  const next: Record<string, number> = {};
  for (const [tag, sinceMs] of Object.entries(input.orphanSinceByTag)) {
    if (!input.retainedTags.has(tag)) {
      next[tag] = sinceMs;
    }
  }
  return next;
}

/** 引用消失时标记 orphan 起始时间（幂等：已有记录不覆盖）。 */
export function markOrphanIfUnreferenced(input: {
  readonly tag: string;
  readonly villageClanTags: readonly string[];
  readonly trackedClanTags: readonly string[];
  readonly playerTags?: readonly string[];
  readonly endpointKind: OrphanCacheEndpointKind;
  readonly orphanSinceByTag: Readonly<Record<string, number>>;
  readonly nowMs: number;
}): Record<string, number> {
  if (
    isOfficialCacheTagReferenced({
      tag: input.tag,
      villageClanTags: input.villageClanTags,
      trackedClanTags: input.trackedClanTags,
      playerTags: input.playerTags,
      endpointKind: input.endpointKind,
    })
  ) {
    return pruneOrphanTimestamps({
      orphanSinceByTag: input.orphanSinceByTag,
      retainedTags: new Set([input.tag]),
    });
  }
  if (input.orphanSinceByTag[input.tag] !== undefined) {
    return { ...input.orphanSinceByTag };
  }
  return { ...input.orphanSinceByTag, [input.tag]: input.nowMs };
}

/** 从 state store 删除 purgeEligible tags，保留其余（per-tag 隔离，不株连）。 */
export function applyOrphanCachePolicy<T>(
  states: Readonly<Record<string, T>>,
  input: {
    readonly villageClanTags: readonly string[];
    readonly trackedClanTags: readonly string[];
    readonly playerTags?: readonly string[];
    readonly endpointKind: OrphanCacheEndpointKind;
    readonly orphanSinceByTag: Readonly<Record<string, number>>;
    readonly nowMs: number;
    readonly orphanTtlMs?: number;
  },
): Record<string, T> {
  const toPurge = new Set(
    purgeEligibleCacheTags({
      cacheTags: Object.keys(states),
      ...input,
    }),
  );
  if (toPurge.size === 0) {
    return { ...states };
  }
  const next: Record<string, T> = {};
  for (const [tag, state] of Object.entries(states)) {
    if (!toPurge.has(tag)) {
      next[tag] = state;
    }
  }
  return next;
}
