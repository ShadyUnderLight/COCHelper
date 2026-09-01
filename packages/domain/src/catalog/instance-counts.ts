import type { CatalogItem } from './types';
import { UNIVERSE_TOWN_HALL_COUNT } from './types';

/** 与 Swift GameCatalog.nonCountableDataIDs / validate.py 同源。 */
export const NON_COUNTABLE_DATA_IDS = new Set<bigint>([
  1_000_001n,
  1_000_103n,
  1_000_104n,
  1_000_022n,
  1_000_025n,
  1_000_030n,
  1_000_066n,
  1_000_016n,
  1_000_017n,
  1_000_018n,
  1_000_061n,
  1_000_069n,
  1_000_062n,
  1_000_074n,
  1_000_076n,
  1_000_060n,
  1_000_087n,
  1_000_088n,
  1_000_094n,
  1_000_095n,
  1_000_096n,
  1_000_073n,
  1_000_075n,
  1_000_083n,
  1_000_090n,
  1_000_091n,
  1_000_092n,
  1_000_098n,
  1_000_099n,
  1_000_100n,
  1_000_101n,
  12_000_003n,
  12_000_004n,
  12_000_007n,
  12_000_017n,
  12_000_018n,
  12_000_019n,
]);

export function catalogItemKey(section: string, dataID: bigint): string {
  return `${section}:${dataID.toString()}`;
}

export function validatedInstanceCounts(
  raw: Readonly<Record<string, readonly number[]>> | null | undefined,
  index: ReadonlyMap<string, CatalogItem>,
): Readonly<Record<string, readonly number[]>> | null {
  if (raw === null || raw === undefined) {
    return null;
  }
  const entries = Object.entries(raw);
  if (entries.length === 0) {
    return null;
  }
  for (const [, values] of entries) {
    if (values.length !== UNIVERSE_TOWN_HALL_COUNT || values.some((value) => value < 0)) {
      return null;
    }
  }
  for (const values of Object.values(raw)) {
    if (values.every((value) => value === 0)) {
      return null;
    }
  }

  const validKeys = new Set<string>();
  for (const [key] of entries) {
    const parts = key.split(':', 2);
    if (parts.length !== 2 || parts[0] === '') {
      return null;
    }
    let dataID: bigint;
    try {
      dataID = BigInt(parts[1]!);
    } catch {
      return null;
    }
    const section = parts[0]!;
    if (key !== catalogItemKey(section, dataID)) {
      return null;
    }
    if (!index.has(catalogItemKey(section, dataID))) {
      return null;
    }
    validKeys.add(catalogItemKey(section, dataID));
  }

  const sectionsWithUniverseKeys = new Set([...validKeys].map((key) => key.split(':', 1)[0]!));

  for (const item of index.values()) {
    const isCoreSection = item.section === 'buildings' || item.section === 'traps';
    if (!isCoreSection && !sectionsWithUniverseKeys.has(item.section)) {
      continue;
    }
    if (item.base !== 'home') {
      continue;
    }
    if (NON_COUNTABLE_DATA_IDS.has(item.dataID)) {
      continue;
    }
    if (!validKeys.has(catalogItemKey(item.section, item.dataID))) {
      return null;
    }
  }

  return raw;
}
