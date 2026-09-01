export const DEFAULT_BUNDLED_CATALOG_VERSION = '18.400.13' as const;

export type CatalogCounts = {
  readonly items: number;
  readonly levels: number;
  readonly missingIcons?: number;
  readonly missingTime?: number;
  readonly timed?: number;
  readonly instant?: number;
  readonly notApplicable?: number;
  readonly initialLevel?: number;
  readonly sourceMissing?: number;
  readonly parseFailed?: number;
};

export type CatalogGeneratedFile = {
  readonly path: string;
  readonly sha256?: string;
  readonly size?: number;
  readonly kind?: string;
  readonly entries?: number;
};

export type CatalogManifest = {
  readonly schemaVersion: number;
  readonly gameVersion: string;
  readonly buildTag: string;
  readonly locale: string;
  readonly sourceFingerprint: string;
  readonly generatedFiles: readonly CatalogGeneratedFile[];
  readonly counts: CatalogCounts;
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

export type FileCheck = (relativePath: string, declaredSize: number | null | undefined) => boolean;

/** manifest generatedFiles 完整性探测（hash / size / directory / entries）。 */
export type GeneratedFileIntegrityProbe = {
  readonly fileExists: (relativePath: string) => boolean;
  readonly directoryExists: (relativePath: string) => boolean;
  readonly fileSize: (relativePath: string) => number | null;
  readonly fileSha256: (relativePath: string) => string | null;
};

export const UNIVERSE_TOWN_HALL_COUNT = 18 as const;
