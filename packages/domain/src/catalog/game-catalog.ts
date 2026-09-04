import type { CatalogCompatibility, CatalogItem, CatalogLevel, CatalogManifest } from './types';
import { DEFAULT_BUNDLED_CATALOG_VERSION, UNIVERSE_TOWN_HALL_COUNT } from './types';
import { catalogItemKey, validatedInstanceCounts } from './instance-counts';

export type GameCatalog = {
  readonly gameVersion: string;
  readonly manifest: CatalogManifest | null;
  readonly item: (section: string, dataID: bigint) => CatalogItem | undefined;
  readonly itemsInSection: (section: string) => readonly CatalogItem[];
  readonly catalogLevel: (nextLevel: number, item: CatalogItem) => CatalogLevel | undefined;
  readonly durationToUpgradeLevel: (nextLevel: number, item: CatalogItem) => bigint | undefined;
  readonly hasUniverseData: boolean;
  readonly universeCount: (
    section: string,
    dataID: bigint,
    townHallLevel: number,
  ) => number | undefined;
  readonly universeKeys: () => readonly { readonly section: string; readonly dataID: bigint }[];
  readonly universeSections: () => ReadonlySet<string>;
};

export function createGameCatalog(input: {
  readonly gameVersion: string;
  readonly items: readonly CatalogItem[];
  readonly manifest?: CatalogManifest | null;
  readonly instanceCounts?: Readonly<Record<string, readonly number[]>> | null;
}): GameCatalog {
  const bySection = new Map<string, CatalogItem[]>();
  const index = new Map<string, CatalogItem>();
  for (const item of input.items) {
    bySection.set(item.section, [...(bySection.get(item.section) ?? []), item]);
    index.set(catalogItemKey(item.section, item.dataID), item);
  }
  const instanceCounts = validatedInstanceCounts(input.instanceCounts ?? null, index);

  function hasUniverseData(): boolean {
    if (instanceCounts === null || Object.keys(instanceCounts).length === 0) {
      return false;
    }
    return true;
  }

  return {
    gameVersion: input.gameVersion,
    manifest: input.manifest ?? null,
    item(section: string, dataID: bigint) {
      return index.get(catalogItemKey(section, dataID));
    },
    itemsInSection(section: string) {
      return bySection.get(section) ?? [];
    },
    catalogLevel(nextLevel: number, item: CatalogItem) {
      if (nextLevel <= 0) {
        return undefined;
      }
      return item.levels.find((level) => level.level === nextLevel);
    },
    durationToUpgradeLevel(nextLevel: number, item: CatalogItem) {
      return this.catalogLevel(nextLevel, item)?.durationSeconds ?? undefined;
    },
    get hasUniverseData() {
      return hasUniverseData();
    },
    universeCount(section: string, dataID: bigint, townHallLevel: number) {
      if (!hasUniverseData()) {
        return undefined;
      }
      if (townHallLevel < 1 || townHallLevel > UNIVERSE_TOWN_HALL_COUNT) {
        return undefined;
      }
      const values = instanceCounts?.[catalogItemKey(section, dataID)];
      return values?.[townHallLevel - 1];
    },
    universeKeys() {
      if (!hasUniverseData() || instanceCounts === null) {
        return [];
      }
      return Object.keys(instanceCounts)
        .map((key) => {
          const parts = key.split(':', 2);
          if (parts.length !== 2) {
            return null;
          }
          try {
            return { section: parts[0]!, dataID: BigInt(parts[1]!) };
          } catch {
            return null;
          }
        })
        .filter((entry): entry is { section: string; dataID: bigint } => entry !== null)
        .sort((left, right) =>
          left.section === right.section
            ? left.dataID < right.dataID
              ? -1
              : left.dataID > right.dataID
                ? 1
                : 0
            : left.section < right.section
              ? -1
              : 1,
        );
    },
    universeSections() {
      if (!hasUniverseData() || instanceCounts === null) {
        return new Set<string>();
      }
      return new Set(
        Object.keys(instanceCounts)
          .map((key) => key.split(':', 1)[0]!)
          .filter((section) => section.length > 0),
      );
    },
  };
}

export function resolveCatalogCompatibility(
  catalog: GameCatalog | null | undefined,
  expectedGameVersion?: string | null,
): CatalogCompatibility {
  if (catalog === null || catalog === undefined) {
    return { kind: 'unavailable' };
  }
  if (
    expectedGameVersion === null ||
    expectedGameVersion === undefined ||
    expectedGameVersion === ''
  ) {
    return { kind: 'unverified', gameVersion: catalog.gameVersion };
  }
  if (expectedGameVersion === catalog.gameVersion) {
    return { kind: 'verified', gameVersion: catalog.gameVersion };
  }
  return {
    kind: 'mismatch',
    catalogVersion: catalog.gameVersion,
    expectedVersion: expectedGameVersion,
  };
}

export function catalogCompatibilityIsUsable(compatibility: CatalogCompatibility): boolean {
  return compatibility.kind === 'unverified' || compatibility.kind === 'verified';
}

export { DEFAULT_BUNDLED_CATALOG_VERSION };
