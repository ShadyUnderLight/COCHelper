import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { craftTableIntegrityOk, loadCraftTableCatalog, resolveCatalogBundleRoot } from './index';

const repoRoot = resolveCatalogBundleRoot(process.cwd());
const describeIfBundle = repoRoot === null ? describe.skip : describe;

describeIfBundle('CraftTableCatalog', () => {
  const versionRoot = join(repoRoot!, '18.400.13');
  const manifestText = readFileSync(join(versionRoot, 'manifest.json'), 'utf8');
  const craftText = readFileSync(join(versionRoot, 'craft_table_catalog.json'), 'utf8');

  it('bundled manifest 完整性通过', () => {
    expect(craftTableIntegrityOk(manifestText, craftText)).toBe(true);
  });

  it('loadBundled 返回 catalog', () => {
    const catalog = loadCraftTableCatalog({
      version: '18.400.13',
      manifestText,
      craftText,
    });
    expect(catalog).not.toBeNull();
    expect(catalog!.defense(103_000_000n)?.name).toBe('钩索塔');
  });

  it('篡改 craft hash 后 fail-closed', () => {
    expect(
      craftTableIntegrityOk(manifestText, craftText.replace('HookTower', 'TamperedTower')),
    ).toBe(false);
  });
});
