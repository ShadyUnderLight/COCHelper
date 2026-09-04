import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

import { decodeCatalogManifest, decodeCatalogPayload, decodeJsonFile } from './json-decode';
import { validateCatalogManifest } from './manifest-validate';
import {
  createGameCatalog,
  DEFAULT_BUNDLED_CATALOG_VERSION,
  type GameCatalog,
} from './game-catalog';
import { loadCraftTableCatalog, type CraftTableCatalog } from './craft-table';
import { loadLeagueTierCatalog, type LeagueTierCatalog } from './league-tier';
import { decodeAccountNameCatalog, type AccountNameCatalog } from './account-name';
import {
  decodeSeasonalPhaseTable,
  EMPTY_SEASONAL_PHASE_TABLE,
  type SeasonalPhaseTable,
} from './seasonal-phase';

export type CatalogBundle = {
  readonly version: string;
  readonly root: string;
  readonly gameCatalog: GameCatalog | null;
  readonly craftTableCatalog: CraftTableCatalog | null;
  readonly leagueTierCatalog: LeagueTierCatalog | null;
  readonly seasonalPhaseTable: SeasonalPhaseTable;
  readonly accountNameCatalog: AccountNameCatalog;
};

export function resolveCatalogBundleRoot(startDir = process.cwd()): string | null {
  let current = resolve(startDir);
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = join(current, 'Sources/COCHelperCore/GameCatalog');
    if (existsSync(candidate)) {
      return candidate;
    }
    const parent = resolve(current, '..');
    if (parent === current) {
      break;
    }
    current = parent;
  }
  return null;
}

export function resolveAccountNameCatalogPath(startDir = process.cwd()): string | null {
  let current = resolve(startDir);
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = join(current, 'Sources/COCHelperCore/Resources/account_name_catalog.json');
    if (existsSync(candidate)) {
      return candidate;
    }
    const parent = resolve(current, '..');
    if (parent === current) {
      break;
    }
    current = parent;
  }
  return null;
}

export async function loadCatalogBundle(input: {
  readonly root: string;
  readonly version?: string;
  readonly accountNameCatalogPath?: string | null;
}): Promise<CatalogBundle> {
  const version = input.version ?? DEFAULT_BUNDLED_CATALOG_VERSION;
  const versionRoot = join(input.root, version);
  const gameCatalog = await loadGameCatalog(versionRoot);
  const manifestText = await readOptional(join(versionRoot, 'manifest.json'));
  const craftText = await readOptional(join(versionRoot, 'craft_table_catalog.json'));
  const craftTableCatalog =
    manifestText !== null && craftText !== null
      ? loadCraftTableCatalog({ version, manifestText, craftText })
      : null;
  const leagueText = await readOptional(join(versionRoot, 'league_tier_catalog.json'));
  const leagueTierCatalog =
    leagueText !== null ? loadLeagueTierCatalog({ version, text: leagueText }) : null;
  const seasonalText = await readOptional(join(versionRoot, 'seasonal_phases.json'));
  const seasonalPhaseTable =
    seasonalText !== null
      ? decodeSeasonalPhaseTable(JSON.parse(seasonalText))
      : EMPTY_SEASONAL_PHASE_TABLE;
  const accountPath =
    input.accountNameCatalogPath ??
    (existsSync(join(input.root, '../Resources/account_name_catalog.json'))
      ? join(input.root, '../Resources/account_name_catalog.json')
      : resolveAccountNameCatalogPath(process.cwd()));
  const accountNameCatalog =
    accountPath !== null && existsSync(accountPath)
      ? decodeAccountNameCatalog(await readFile(accountPath, 'utf8'))
      : decodeAccountNameCatalog('{"entries":{}}');

  return {
    version,
    root: input.root,
    gameCatalog,
    craftTableCatalog,
    leagueTierCatalog,
    seasonalPhaseTable,
    accountNameCatalog,
  };
}

async function loadGameCatalog(versionRoot: string): Promise<GameCatalog | null> {
  const catalogPath = join(versionRoot, 'catalog.json');
  const manifestPath = join(versionRoot, 'manifest.json');
  try {
    const [catalogText, manifestText] = await Promise.all([
      readFile(catalogPath, 'utf8'),
      readFile(manifestPath, 'utf8'),
    ]);
    const payload = decodeCatalogPayload(catalogText);
    let manifest = null;
    try {
      const decodedManifest = decodeJsonFile(manifestText, decodeCatalogManifest);
      if (
        decodedManifest.gameVersion === payload.gameVersion &&
        validateCatalogManifest(decodedManifest, payload.items)
      ) {
        manifest = decodedManifest;
      }
    } catch {
      manifest = null;
    }
    return createGameCatalog({
      gameVersion: payload.gameVersion,
      items: payload.items,
      manifest,
      instanceCounts: payload.instanceCounts,
    });
  } catch {
    return null;
  }
}

async function readOptional(path: string): Promise<string | null> {
  try {
    return await readFile(path, 'utf8');
  } catch {
    return null;
  }
}

export type CatalogBundleCache = {
  readonly get: () => Promise<CatalogBundle>;
  readonly peek: () => CatalogBundle | null;
  readonly reset: () => void;
};

export function createCatalogBundleCache(input: {
  readonly root: string;
  readonly version?: string;
  readonly accountNameCatalogPath?: string | null;
}): CatalogBundleCache {
  let cached: Promise<CatalogBundle> | null = null;
  let resolved: CatalogBundle | null = null;
  return {
    get() {
      if (cached === null) {
        cached = loadCatalogBundle(input).then((bundle) => {
          resolved = bundle;
          return bundle;
        });
      }
      return cached;
    },
    peek() {
      return resolved;
    },
    reset() {
      cached = null;
      resolved = null;
    },
  };
}
