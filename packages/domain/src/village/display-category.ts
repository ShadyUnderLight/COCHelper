import type { GameCatalog } from '../catalog/game-catalog';
import type { TrackerBase, TrackerDisplayCategory } from './tracker';

export const CRAFT_TABLE_DATA_ID = 1000097n;

/** 平铺 id 的根父段：`"buildings:6.types.0.modules.2"` → `"buildings:6"`。 */
export function rootIdOfItemId(id: string): string {
  const dot = id.indexOf('.');
  return dot === -1 ? id : id.slice(0, dot);
}

export function resolveDisplayCategory(input: {
  readonly section: string;
  readonly dataID: bigint;
  readonly base: TrackerBase;
  readonly rootParentDataID: bigint | null;
  readonly catalog: GameCatalog | null | undefined;
}): TrackerDisplayCategory | undefined {
  const { section, dataID, base, rootParentDataID, catalog } = input;
  if (section !== 'buildings' || base !== 'home') {
    return undefined;
  }

  const effectiveDataID = rootParentDataID ?? dataID;
  const raw = catalog?.item('buildings', effectiveDataID)?.displayCategory;
  if (raw !== null && raw !== undefined) {
    switch (raw) {
      case 'defense':
      case 'walls':
      case 'military':
      case 'craftTable':
        return raw;
      default:
        return undefined;
    }
  }

  if (effectiveDataID === CRAFT_TABLE_DATA_ID) {
    return 'craftTable';
  }

  return undefined;
}
