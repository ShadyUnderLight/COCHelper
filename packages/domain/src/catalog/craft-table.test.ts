import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { loadCraftTableCatalog, resolveCatalogBundleRoot } from './index';

const repoRoot = resolveCatalogBundleRoot(process.cwd());
const describeIfBundle = repoRoot === null ? describe.skip : describe;

describeIfBundle('CraftTableCatalog', () => {
  const versionRoot = join(repoRoot!, '18.400.13');
  const manifestText = readFileSync(join(versionRoot, 'manifest.json'), 'utf8');
  const craftText = readFileSync(join(versionRoot, 'craft_table_catalog.json'), 'utf8');

  it('loadBundled 返回 catalog（V3 manifest，无 hash 对账）', () => {
    const catalog = loadCraftTableCatalog({
      version: '18.400.13',
      manifestText,
      craftText,
    });
    expect(catalog).not.toBeNull();
    expect(catalog!.defense(103_000_000n)?.name).toBe('钩索塔');
  });

  it('旧 schemaVersion manifest 被拒绝', () => {
    const oldManifest = JSON.stringify({
      schemaVersion: 2,
      gameVersion: '18.400.13',
      buildTag: '18_400_7',
      locale: 'zh-CN',
    });
    expect(
      loadCraftTableCatalog({ version: '18.400.13', manifestText: oldManifest, craftText }),
    ).toBeNull();
  });

  it('版本不一致时返回 null', () => {
    expect(loadCraftTableCatalog({ version: '9.999.0', manifestText, craftText })).toBeNull();
  });

  it('同 gameVersion 不同 buildTag 时拒绝（业务版本绑定）', () => {
    const manifest = JSON.parse(manifestText) as { buildTag: string };
    manifest.buildTag = '19_0_0';
    expect(
      loadCraftTableCatalog({
        version: '18.400.13',
        manifestText: JSON.stringify(manifest),
        craftText,
      }),
    ).toBeNull();
  });

  it('craft 内容损坏时返回 null', () => {
    expect(
      loadCraftTableCatalog({ version: '18.400.13', manifestText, craftText: 'not-json' }),
    ).toBeNull();
  });
});
