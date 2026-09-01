import { resolveCatalogBundleRoot } from '@coc-helper/domain';
import { describe, expect, it } from 'vitest';

import {
  createCatalogService,
  resetCatalogServiceForTests,
} from './catalog-service';

const repoRoot = resolveCatalogBundleRoot(process.cwd());
const describeIfBundle = repoRoot === null ? describe.skip : describe;

describeIfBundle('catalog-service', () => {
  it('生成 catalog asset URL 并解析路径', async () => {
    resetCatalogServiceForTests();
    const service = createCatalogService({ root: repoRoot! });
    service.preload();
    const bundle = await service.getBundle();
    expect(bundle.gameCatalog).not.toBeNull();
    const samplePath = 'icons/buildings/BB_xbow_lvl1.png';
    const url = service.assetUrl('18.400.13', samplePath);
    expect(url).toBe('cochelper://catalog/18.400.13/icons/buildings/BB_xbow_lvl1.png');
    expect(service.resolveAssetPath('18.400.13', '/18.400.13/icons/buildings/BB_xbow_lvl1.png')).toContain(
      'BB_xbow_lvl1.png',
    );
  }, 15_000);

  it('重复读取命中缓存', async () => {
    resetCatalogServiceForTests();
    const service = createCatalogService({ root: repoRoot! });
    const first = await service.getBundle();
    const second = await service.getBundle();
    expect(first).toBe(second);
  }, 15_000);
});

describe('catalog-service guards', () => {
  it('拒绝非法 renderedPath URL', () => {
    resetCatalogServiceForTests();
    const service = createCatalogService({ root: repoRoot ?? '/tmp' });
    expect(service.assetUrl('18.400.13', '../secret.png')).toBeNull();
  });
});
