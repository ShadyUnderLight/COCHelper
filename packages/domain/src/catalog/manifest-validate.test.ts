import { describe, expect, it } from 'vitest';

import type { CatalogItem, CatalogLevel, CatalogManifest } from './types';
import { validateCatalogManifest } from './manifest-validate';

function makeLevel(
  durationSeconds: bigint | null = 3600n,
  missingReason: string | null = null,
): CatalogLevel {
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

function makeManifest(overrides: Partial<CatalogManifest> = {}): CatalogManifest {
  return {
    schemaVersion: 3,
    gameVersion: '18.400.13',
    buildTag: '18_400_7',
    locale: 'zh-CN',
    ...overrides,
  };
}

describe('validateCatalogManifest', () => {
  it('V3 manifest + 合法 items 时通过', () => {
    expect(validateCatalogManifest(makeManifest(), [makeItem()])).toBe(true);
  });

  it('旧 schemaVersion 1/2 按 §WA-7.1 拒绝', () => {
    expect(validateCatalogManifest(makeManifest({ schemaVersion: 1 }), [makeItem()])).toBe(false);
    expect(validateCatalogManifest(makeManifest({ schemaVersion: 2 }), [makeItem()])).toBe(false);
  });

  it('schemaVersion 超范围时 fail-closed', () => {
    expect(validateCatalogManifest(makeManifest({ schemaVersion: 99 }), [makeItem()])).toBe(false);
  });

  it('AssetRef both-present 时 fail-closed', () => {
    const item: CatalogItem = {
      ...makeItem(),
      icon: {
        container: 'sc/ui.sc',
        exportName: 'icon_x',
        renderedPath: 'icons/ui/icon_x.png',
        missingReason: 'export_not_found',
      },
    };
    expect(validateCatalogManifest(makeManifest(), [item])).toBe(false);
  });

  it('AssetRef 格式非法时 fail-closed', () => {
    const item: CatalogItem = {
      ...makeItem(),
      icon: {
        container: 'sc/ui.sc',
        exportName: 'icon_x',
        renderedPath: '../evil.png',
        missingReason: null,
      },
    };
    expect(validateCatalogManifest(makeManifest(), [item])).toBe(false);
  });

  it('AssetRef null/null no-reference 合法', () => {
    const item: CatalogItem = {
      ...makeItem(),
      icon: {
        container: 'sc/ui.sc',
        exportName: 'icon_x',
        renderedPath: null,
        missingReason: null,
      },
    };
    expect(validateCatalogManifest(makeManifest(), [item])).toBe(true);
  });

  it('renderable ref 无需任何登记即通过（R-C 已撤销）', () => {
    const item: CatalogItem = {
      ...makeItem(),
      icon: {
        container: 'sc/ui.sc',
        exportName: 'icon_x',
        renderedPath: 'icons/ui/icon_x.png',
        missingReason: null,
      },
    };
    expect(validateCatalogManifest(makeManifest(), [item])).toBe(true);
  });
});
