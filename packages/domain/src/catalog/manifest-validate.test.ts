import { sha256Fingerprint } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import type { CatalogItem, CatalogLevel, CatalogManifest } from './types';
import { validateCatalogManifest } from './manifest-validate';

function makeLevel(durationSeconds: bigint | null = 3600n, missingReason: string | null = null): CatalogLevel {
  return {
    level: 1,
    durationSeconds,
    upgradeCosts: null,
    requiredTownHallLevel: null,
    requiredLaboratoryLevel: null,
    requiredHeroTavernLevel: null,
    requiredBlacksmithLevel: null,
    icon: null,
    levelVisual: null,
    missingReason,
  };
}

function makeItem(levels: readonly CatalogLevel[] = [makeLevel()]): CatalogItem {
  return {
    section: 'units',
    category: 'troops',
    dataID: 1n,
    base: 'home',
    baseMissingReason: null,
    name: 'x',
    maxLevel: 1,
    icon: null,
    levelVisual: null,
    missingReason: null,
    displayCategory: null,
    lifecycle: null,
    levels,
  };
}

function makeManifest(overrides: Partial<CatalogManifest> & { counts?: Partial<CatalogManifest['counts']> } = {}): CatalogManifest {
  return {
    schemaVersion: 1,
    gameVersion: '18.400.13',
    buildTag: '18_400_7',
    locale: 'zh-CN',
    sourceFingerprint: `sha256:${'a'.repeat(64)}`,
    generatedFiles: [
      { path: 'catalog.json', sha256: overrides.generatedFiles?.[0]?.sha256 },
    ],
    counts: {
      items: 1,
      levels: 1,
      missingTime: 0,
      ...overrides.counts,
    },
    ...overrides,
  };
}

describe('validateCatalogManifest', () => {
  it('counts 与 sha256 一致时通过', () => {
    const item = makeItem();
    const catalogData = 'consistent-catalog';
    const sha = sha256Fingerprint(catalogData).slice('sha256:'.length);
    const manifest = makeManifest({
      generatedFiles: [{ path: 'catalog.json', sha256: `sha256:${sha}` }],
    });
    expect(validateCatalogManifest(manifest, [item], catalogData)).toBe(true);
  });

  it('counts 不一致时 fail-closed', () => {
    const manifest = makeManifest({ counts: { items: 999, levels: 999, missingTime: 0 } });
    expect(validateCatalogManifest(manifest, [makeItem()], '')).toBe(false);
  });

  it('missingTime 不一致时 fail-closed', () => {
    const manifest = makeManifest({ counts: { items: 1, levels: 1, missingTime: 5 } });
    expect(validateCatalogManifest(manifest, [makeItem()], '')).toBe(false);
  });

  it('sha256 不一致时 fail-closed', () => {
    const manifest = makeManifest({
      generatedFiles: [{ path: 'catalog.json', sha256: `sha256:${'0'.repeat(64)}` }],
    });
    expect(validateCatalogManifest(manifest, [makeItem()], 'tampered')).toBe(false);
  });

  it('timed 桶不一致时 fail-closed', () => {
    const manifest = makeManifest({ counts: { items: 1, levels: 1, missingTime: 0, timed: 0, instant: 0 } });
    expect(validateCatalogManifest(manifest, [makeItem()], '')).toBe(false);
  });

  it('sha256 前缀非法时 fail-closed', () => {
    const manifest = makeManifest({
      generatedFiles: [{ path: 'catalog.json', sha256: '0'.repeat(64) }],
    });
    expect(validateCatalogManifest(manifest, [makeItem()], '')).toBe(false);
  });

  it('sha256 缺失时向后兼容跳过', () => {
    const manifest = makeManifest({ generatedFiles: [{ path: 'catalog.json' }] });
    expect(validateCatalogManifest(manifest, [makeItem()], '')).toBe(true);
  });

  it('schemaVersion 超范围时 fail-closed', () => {
    const manifest = makeManifest({ schemaVersion: 99 });
    expect(validateCatalogManifest(manifest, [makeItem()], '')).toBe(false);
  });

  it('sourceFingerprint 非法时 fail-closed', () => {
    const manifest = makeManifest({ sourceFingerprint: 'md5:deadbeef' });
    expect(validateCatalogManifest(manifest, [makeItem()], '')).toBe(false);
  });

  it('generatedFiles 缺失时 fail-closed', () => {
    const manifest = makeManifest({
      generatedFiles: [
        { path: 'catalog.json' },
        { path: 'icons/buildings/missing.png', size: 100 },
      ],
    });
    const fileCheck = (path: string) => path !== 'icons/buildings/missing.png';
    expect(validateCatalogManifest(manifest, [makeItem()], '', fileCheck)).toBe(false);
  });

  it('size 不匹配时 fail-closed', () => {
    const manifest = makeManifest({
      generatedFiles: [
        { path: 'catalog.json' },
        { path: 'icons/buildings/tower.png', size: 100 },
      ],
    });
    const fileCheck = (_path: string, size: number | null | undefined) => size !== 100;
    expect(validateCatalogManifest(manifest, [makeItem()], '', fileCheck)).toBe(false);
  });

  it('renderedPath 缺失时 fail-closed', () => {
    const item: CatalogItem = {
      ...makeItem(),
      icon: {
        container: 'sc/ui.sc',
        exportName: 'icon_x',
        renderedPath: 'icons/ui/icon_x.png',
        missingReason: null,
      },
    };
    const manifest = makeManifest({ generatedFiles: [{ path: 'catalog.json' }] });
    const fileCheck = (path: string) => path !== 'icons/ui/icon_x.png';
    expect(validateCatalogManifest(manifest, [item], '', fileCheck)).toBe(false);
  });
});
