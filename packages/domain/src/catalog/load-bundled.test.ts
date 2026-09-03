import { describe, expect, it } from 'vitest';

import { loadCatalogBundle, resolveCatalogBundleRoot } from './load-bundled';

const repoRoot = resolveCatalogBundleRoot(process.cwd());
const describeIfBundle = repoRoot === null ? describe.skip : describe;

describeIfBundle('loadCatalogBundle', () => {
  it('加载 bundled 目录：V3 manifest，无 hash 字段', async () => {
    const bundle = await loadCatalogBundle({ root: repoRoot!, version: '18.400.13' });
    expect(bundle.gameCatalog).not.toBeNull();
    expect(bundle.gameCatalog!.gameVersion).toBe('18.400.13');
    const manifest = bundle.gameCatalog!.manifest;
    expect(manifest).not.toBeNull();
    expect(manifest!.schemaVersion).toBe(3);
    expect(manifest).not.toHaveProperty('sourceFingerprint');
    expect(manifest).not.toHaveProperty('generatedFiles');
    expect(manifest).not.toHaveProperty('counts');
  });

  it('craft table 可用，宇宙数据可用（业务校验通过）', async () => {
    const bundle = await loadCatalogBundle({ root: repoRoot!, version: '18.400.13' });
    expect(bundle.craftTableCatalog).not.toBeNull();
    expect(bundle.gameCatalog!.hasUniverseData).toBe(true);
  });

  it('未知版本返回空目录（null catalogs）', async () => {
    const bundle = await loadCatalogBundle({ root: repoRoot!, version: '0.0.0' });
    expect(bundle.gameCatalog).toBeNull();
    expect(bundle.craftTableCatalog).toBeNull();
  });
});
