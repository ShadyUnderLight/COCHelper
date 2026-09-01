import { generateUuid, sha256Fingerprint } from '@coc-helper/wire';

import type { AccountItem, AccountSnapshot } from '../account';
import { createGameCatalog, type GameCatalog } from '../catalog/game-catalog';
import type { CatalogItem, CatalogLevel } from '../catalog/types';
import { createVillageProfile, type VillageProfile } from '../import/types';

const IMPORTED_AT_MS = 1_700_000_000_000;

function level(
  levelNumber: number,
  durationSeconds: bigint | null,
  options: {
    readonly requiredTownHallLevel?: number | null;
    readonly requiredLaboratoryLevel?: number | null;
    readonly requiredHeroTavernLevel?: number | null;
    readonly requiredBlacksmithLevel?: number | null;
    readonly missingReason?: string | null;
  } = {},
): CatalogLevel {
  return {
    level: levelNumber,
    durationSeconds,
    upgradeCosts: null,
    requiredTownHallLevel: options.requiredTownHallLevel ?? null,
    requiredLaboratoryLevel: options.requiredLaboratoryLevel ?? null,
    requiredHeroTavernLevel: options.requiredHeroTavernLevel ?? null,
    requiredBlacksmithLevel: options.requiredBlacksmithLevel ?? null,
    icon: null,
    levelVisual: null,
    missingReason: options.missingReason ?? null,
  };
}

function catalogItem(input: {
  readonly section: string;
  readonly category: string;
  readonly dataID: bigint;
  readonly base: string;
  readonly name: string;
  readonly maxLevel: number;
  readonly levels: readonly CatalogLevel[];
  readonly displayCategory?: string | null;
}): CatalogItem {
  return {
    section: input.section,
    category: input.category,
    dataID: input.dataID,
    base: input.base,
    baseMissingReason: null,
    name: input.name,
    maxLevel: input.maxLevel,
    icon: null,
    levelVisual: null,
    missingReason: null,
    displayCategory: input.displayCategory ?? null,
    lifecycle: null,
    levels: input.levels,
  };
}

export function createSyntheticCatalog(): GameCatalog {
  return createGameCatalog({
    gameVersion: '18.400.13',
    items: [
      catalogItem({
        section: 'buildings',
        category: 'buildings',
        dataID: 1_000_001n,
        base: 'home',
        name: '加农炮',
        maxLevel: 2,
        levels: [
          level(1, 60n, { requiredTownHallLevel: 1 }),
          level(2, 300n, { requiredTownHallLevel: 2 }),
        ],
      }),
      catalogItem({
        section: 'units',
        category: 'troops',
        dataID: 4_000_000n,
        base: 'home',
        name: '野蛮人',
        maxLevel: 3,
        levels: [
          level(1, null, { missingReason: 'min_level_initial_no_upgrade' }),
          level(2, 1800n, { requiredLaboratoryLevel: 1 }),
          level(3, 3600n, { requiredLaboratoryLevel: 1 }),
        ],
      }),
      catalogItem({
        section: 'buildings2',
        category: 'buildings',
        dataID: 1_000_033n,
        base: 'builder',
        name: '建筑工人小屋',
        maxLevel: 2,
        levels: [level(1, 60n), level(2, 600n)],
      }),
      catalogItem({
        section: 'equipment',
        category: 'equipment',
        dataID: 90_000_000n,
        base: 'home',
        name: '野蛮人木偶',
        maxLevel: 3,
        levels: [
          level(1, null, { missingReason: 'no_direct_upgrade_time' }),
          level(2, null, { missingReason: 'no_direct_upgrade_time' }),
          level(3, null, { missingReason: 'no_direct_upgrade_time' }),
        ],
      }),
    ],
  });
}

export function makeAccountItem(input: {
  readonly section: string;
  readonly dataID: bigint;
  readonly level?: number | null;
  readonly count?: number | null;
  readonly timerSeconds?: bigint | null;
  readonly remainingSeconds?: bigint | null;
  readonly types?: readonly AccountItem[];
  readonly modules?: readonly AccountItem[];
  readonly path?: string;
}): AccountItem {
  const path = input.path ?? '0';
  return {
    id: `${input.section}:${path}`,
    section: input.section,
    dataID: input.dataID,
    level: input.level ?? null,
    count: input.count ?? null,
    timerSeconds: input.timerSeconds ?? null,
    remainingSeconds: input.remainingSeconds ?? null,
    helperTimerSeconds: null,
    remainingHelperSeconds: null,
    helperCooldownSeconds: null,
    remainingHelperCooldownSeconds: null,
    helperRecurrent: false,
    gearUp: null,
    weapon: null,
    types: input.types ?? [],
    modules: input.modules ?? [],
  };
}

export function makeTestSnapshot(
  objectSections: Readonly<Record<string, readonly AccountItem[]>>,
): AccountSnapshot {
  return {
    tag: '#TEST',
    capturedAtMs: null,
    importedAtMs: IMPORTED_AT_MS,
    ageSeconds: null,
    originalText: '',
    objectSections,
    numericSections: {},
    boosts: {},
    unknownTopLevelKeys: [],
    diagnostics: [],
    contentFingerprint: sha256Fingerprint(
      'sha256:0000000000000000000000000000000000000000000000000000000000000000',
    ),
  };
}

export function makeTestVillage(
  objectSections: Readonly<Record<string, readonly AccountItem[]>>,
): VillageProfile {
  return createVillageProfile({
    id: generateUuid(),
    name: '测试村庄',
    accountSnapshot: makeTestSnapshot(objectSections),
  });
}

export const TEST_IMPORTED_AT_MS = IMPORTED_AT_MS;
