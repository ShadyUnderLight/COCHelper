import type { AccountSnapshot } from '../account';

export const UNLOCK_BUILDING_DATA_IDS = {
  townHall: 1000001n,
  laboratory: 1000007n,
  heroHall: 1000071n,
  blacksmith: 1000070n,
  builderHall: 1000034n,
  starLaboratory: 1000046n,
} as const;

export type PlayerUnlockLevels = {
  readonly townHall: number | null;
  readonly laboratory: number | null;
  readonly heroHall: number | null;
  readonly blacksmith: number | null;
  readonly builderHall: number | null;
  readonly starLaboratory: number | null;
};

export function playerUnlockLevelsFromSnapshot(
  snapshot: AccountSnapshot | null | undefined,
  manualCore: unknown | null = null,
): PlayerUnlockLevels {
  void manualCore;

  function firstLevel(section: string, dataID: bigint): number | null {
    const items = snapshot?.objectSections[section];
    return items?.find((item) => item.dataID === dataID)?.level ?? null;
  }

  return {
    townHall: firstLevel('buildings', UNLOCK_BUILDING_DATA_IDS.townHall),
    laboratory: firstLevel('buildings', UNLOCK_BUILDING_DATA_IDS.laboratory),
    heroHall: firstLevel('buildings', UNLOCK_BUILDING_DATA_IDS.heroHall),
    blacksmith: firstLevel('buildings', UNLOCK_BUILDING_DATA_IDS.blacksmith),
    builderHall: firstLevel('buildings2', UNLOCK_BUILDING_DATA_IDS.builderHall),
    starLaboratory: firstLevel('buildings2', UNLOCK_BUILDING_DATA_IDS.starLaboratory),
  };
}
