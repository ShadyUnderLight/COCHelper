import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  DEFAULT_BUNDLED_CATALOG_VERSION,
  createCatalogBundleCache,
  isCatalogAssetRenderable,
  resolveCatalogBundleRoot,
} from './index';

const repoRoot = resolveCatalogBundleRoot(process.cwd());
const describeIfBundle = repoRoot === null ? describe.skip : describe;

describeIfBundle('GameCatalog bundled load', () => {
  it('加载 18.400.13 并暴露 manifest', async () => {
    const cache = createCatalogBundleCache({
      root: repoRoot!,
      version: DEFAULT_BUNDLED_CATALOG_VERSION,
    });
    const bundle = await cache.get();
    expect(cache.peek()).toBe(bundle);
    expect(bundle.gameCatalog).not.toBeNull();
    expect(bundle.gameCatalog!.gameVersion).toBe('18.400.13');
    expect(bundle.gameCatalog!.manifest).not.toBeNull();
    expect(bundle.gameCatalog!.itemsInSection('buildings').length).toBeGreaterThan(0);
    expect(bundle.gameCatalog!.item('units', 4_000_000n)?.name).toBe('野蛮人');
    expect(bundle.craftTableCatalog).not.toBeNull();
    expect(bundle.leagueTierCatalog).not.toBeNull();
    expect(bundle.accountNameCatalog.count).toBeGreaterThan(0);
  }, 15_000);

  it('建筑/单位 duration 语义与 Swift 对齐', async () => {
    const bundle = await createCatalogBundleCache({ root: repoRoot! }).get();
    const catalog = bundle.gameCatalog!;
    const barracks = catalog.item('buildings', 1_000_000n)!;
    const barbarian = catalog.item('units', 4_000_000n)!;
    expect(catalog.durationToUpgradeLevel(2, barracks)).toBe(300n);
    expect(catalog.durationToUpgradeLevel(2, barbarian)).toBe(1800n);
    expect(catalog.durationToUpgradeLevel(1, barracks)).toBe(60n);
    expect(catalog.durationToUpgradeLevel(1, barbarian)).toBeUndefined();
  }, 15_000);

  it('真实 icon ref 遵守 isRenderable 真值表', async () => {
    const bundle = await createCatalogBundleCache({ root: repoRoot! }).get();
    const item = bundle.gameCatalog!.item('units', 4_000_000n)!;
    if (item.icon !== null && item.icon.renderedPath !== null && item.icon.missingReason === null) {
      expect(isCatalogAssetRenderable(item.icon)).toBe(true);
    }
  }, 15_000);
});

describe('resolveCatalogBundleRoot', () => {
  it('从 monorepo cwd 找到 GameCatalog', () => {
    expect(resolveCatalogBundleRoot(resolve(process.cwd()))).toContain('GameCatalog');
  });
});
