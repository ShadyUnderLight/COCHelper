export const DEFAULT_BUNDLED_CATALOG_VERSION = '18.400.13' as const;

/** E0-03/Issue #303 新契约 CatalogManifestV3：只保留版本/构建元数据四字段。
 * 旧 schemaVersion 1/2（sourceFingerprint / generatedFiles / counts）按
 * wire-contract §WA-7.1 标记不可用，需重新生成。 */
export type CatalogManifest = {
  readonly schemaVersion: number;
  readonly gameVersion: string;
  readonly buildTag: string;
  readonly locale: string;
};

export type CatalogAssetRef = {
  readonly container: string | null;
  readonly exportName: string | null;
  readonly renderedPath: string | null;
  readonly missingReason: string | null;
};

export type CatalogUpgradeCost = {
  readonly resource: string;
  readonly amount: bigint | null;
  readonly rawResource: string | null;
  readonly rawAmount: string | null;
  readonly parseFailed: boolean;
};

export type CatalogLevel = {
  readonly level: number;
  readonly durationSeconds: bigint | null;
  readonly upgradeCosts: readonly CatalogUpgradeCost[] | null;
  readonly requiredTownHallLevel: number | null;
  readonly requiredLaboratoryLevel: number | null;
  readonly requiredHeroTavernLevel: number | null;
  readonly requiredBlacksmithLevel: number | null;
  readonly icon: CatalogAssetRef | null;
  readonly levelVisual: CatalogAssetRef | null;
  readonly missingReason: string | null;
};

export type CatalogLifecycle = 'permanent' | 'seasonalCandidate';

export type CatalogItem = {
  readonly section: string;
  readonly category: string;
  readonly dataID: bigint;
  readonly base: string | null;
  readonly baseMissingReason: string | null;
  readonly name: string;
  readonly maxLevel: number;
  readonly icon: CatalogAssetRef | null;
  readonly levelVisual: CatalogAssetRef | null;
  readonly missingReason: string | null;
  readonly displayCategory: string | null;
  readonly lifecycle: CatalogLifecycle | null;
  readonly levels: readonly CatalogLevel[];
};

export type CatalogCompatibility =
  | { readonly kind: 'unverified'; readonly gameVersion: string }
  | { readonly kind: 'verified'; readonly gameVersion: string }
  | { readonly kind: 'mismatch'; readonly catalogVersion: string; readonly expectedVersion: string }
  | { readonly kind: 'unavailable' };

export const UNIVERSE_TOWN_HALL_COUNT = 18 as const;
