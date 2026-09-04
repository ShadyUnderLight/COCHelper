/** 独立 snapshot-history 契约版本号（对齐 SnapshotHistorySchema.swift）。 */
export const SNAPSHOT_HISTORY_SCHEMA = {
  /** v2（Issue #304）：移除 fingerprint/integrity 摘要字段的新 wire 形状。旧文件按旧 schema 标记不可用。 */
  envelope: 2,
  /** v2（Issue #304）：移除 canonicalFingerprint/integrityFingerprint/version 字段。 */
  entry: 2,
  /** v2：section coverage 证据（Issue #164/#173）。 */
  observationWithSectionEvidence: 2,
  /** v3：timer evidence allowlist（Issue #175）。 */
  observationWithTimerAllowlist: 3,
  /** v4：source timer schema 契约（Issue #175）。 */
  observationWithTimerSchema: 4,
  /** v5：顶层 coverage 从 observation 移除（Issue #208）。 */
  observationWithoutCoverageMetadata: 5,
  /** v6：coverage 冻结 source universe（Issue #236）。 */
  observationWithSourceUniverse: 6,
  observation: 6,
} as const;

/** canonicalization traversal 硬上限（Issue #273 深层嵌套防护）。 */
export const SNAPSHOT_HISTORY_CANONICALIZATION_LIMITS = {
  maxNestedDepth: 64,
  maxItemsPerEntry: 131_072,
} as const;
