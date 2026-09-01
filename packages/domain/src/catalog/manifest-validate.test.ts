import { sha256Fingerprint } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import type {
  CatalogItem,
  CatalogLevel,
  CatalogManifest,
  GeneratedFileIntegrityProbe,
} from './types';
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

function makeManifest(
  overrides: Partial<CatalogManifest> & { counts?: Partial<CatalogManifest['counts']> } = {},
): CatalogManifest {
  return {
    schemaVersion: 1,
    gameVersion: '18.400.13',
    buildTag: '18_400_7',
    locale: 'zh-CN',
    sourceFingerprint: `sha256:${'a'.repeat(64)}`,
    generatedFiles: [{ path: 'catalog.json', sha256: overrides.generatedFiles?.[0]?.sha256 }],
    counts: {
      items: 1,
      levels: 1,
      missingTime: 0,
      ...overrides.counts,
    },
    ...overrides,
  };
}

function makeProbe(
  overrides: Partial<GeneratedFileIntegrityProbe> = {},
): GeneratedFileIntegrityProbe {
  return {
    fileExists: () => true,
    directoryExists: () => true,
    fileSize: () => 5,
    fileSha256: () => `sha256:${'b'.repeat(64)}`,
    ...overrides,
  };
}

describe('validateCatalogManifest', () => {
  it('counts 与 sha256 一致时通过', () => {
    const item = makeItem();
    const catalogData = 'consistent-catalog';
    const sha = sha256Fingerprint(catalogData);
    const manifest = makeManifest({
      generatedFiles: [{ path: 'catalog.json', sha256: sha, size: catalogData.length }],
    });
    const probe = makeProbe({
      fileSha256: (path) => (path === 'catalog.json' ? sha : null),
      fileSize: () => catalogData.length,
    });
    expect(validateCatalogManifest(manifest, [item], catalogData, probe)).toBe(true);
  });

  it('counts 不一致时 fail-closed', () => {
    const manifest = makeManifest({ counts: { items: 999, levels: 999, missingTime: 0 } });
    expect(validateCatalogManifest(manifest, [makeItem()], '', makeProbe())).toBe(false);
  });

  it('missingTime 不一致时 fail-closed', () => {
    const manifest = makeManifest({ counts: { items: 1, levels: 1, missingTime: 5 } });
    expect(validateCatalogManifest(manifest, [makeItem()], '', makeProbe())).toBe(false);
  });

  it('catalog sha256 不一致时 fail-closed', () => {
    const manifest = makeManifest({
      generatedFiles: [{ path: 'catalog.json', sha256: `sha256:${'0'.repeat(64)}`, size: 7 }],
    });
    expect(validateCatalogManifest(manifest, [makeItem()], 'tampered', makeProbe())).toBe(false);
  });

  it('timed 桶不一致时 fail-closed', () => {
    const manifest = makeManifest({
      counts: { items: 1, levels: 1, missingTime: 0, timed: 0, instant: 0 },
    });
    expect(validateCatalogManifest(manifest, [makeItem()], '', makeProbe())).toBe(false);
  });

  it('sha256 前缀非法时 fail-closed', () => {
    const manifest = makeManifest({
      generatedFiles: [{ path: 'catalog.json', sha256: '0'.repeat(64), size: 0 }],
    });
    expect(validateCatalogManifest(manifest, [makeItem()], '', makeProbe())).toBe(false);
  });

  it('无 integrity probe 时向后兼容跳过 generatedFiles 文件级校验', () => {
    const manifest = makeManifest({ generatedFiles: [{ path: 'catalog.json' }] });
    expect(validateCatalogManifest(manifest, [makeItem()], 'x')).toBe(true);
  });

  it('schemaVersion 超范围时 fail-closed', () => {
    const manifest = makeManifest({ schemaVersion: 99 });
    expect(validateCatalogManifest(manifest, [makeItem()], '', makeProbe())).toBe(false);
  });

  it('sourceFingerprint 非法时 fail-closed', () => {
    const manifest = makeManifest({ sourceFingerprint: 'md5:deadbeef' });
    expect(validateCatalogManifest(manifest, [makeItem()], '', makeProbe())).toBe(false);
  });

  it('generatedFiles 文件缺失时 fail-closed', () => {
    const manifest = makeManifest({
      generatedFiles: [
        { path: 'catalog.json', sha256: `sha256:${'b'.repeat(64)}`, size: 5 },
        { path: 'icons/buildings/missing.png', sha256: `sha256:${'c'.repeat(64)}`, size: 100 },
      ],
    });
    const probe = makeProbe({
      fileExists: (path) => path !== 'icons/buildings/missing.png',
    });
    expect(validateCatalogManifest(manifest, [makeItem()], 'bytes', probe)).toBe(false);
  });

  it('same-size 内容损坏仍 fail-closed（sha256 不匹配）', () => {
    const declared = `sha256:${'a'.repeat(64)}`;
    const manifest = makeManifest({
      generatedFiles: [
        {
          path: 'icons/buildings/tower.png',
          sha256: declared,
          size: 100,
        },
      ],
    });
    const probe = makeProbe({
      fileExists: () => true,
      fileSize: () => 100,
      fileSha256: () => `sha256:${'b'.repeat(64)}`,
    });
    expect(validateCatalogManifest(manifest, [makeItem()], '', probe)).toBe(false);
  });

  it('generated file sha256 不匹配时 fail-closed', () => {
    const manifest = makeManifest({
      generatedFiles: [
        {
          path: 'icons/buildings/tower.png',
          sha256: `sha256:${'a'.repeat(64)}`,
          size: 100,
        },
      ],
    });
    const probe = makeProbe({
      fileSha256: () => `sha256:${'b'.repeat(64)}`,
      fileSize: () => 100,
    });
    expect(validateCatalogManifest(manifest, [makeItem()], '', probe)).toBe(false);
  });

  it('generated directory 缺失时 fail-closed', () => {
    const manifest = makeManifest({
      generatedFiles: [{ path: 'icons/', kind: 'directory', entries: 1 }],
    });
    const probe = makeProbe({ directoryExists: () => false });
    expect(validateCatalogManifest(manifest, [makeItem()], '', probe)).toBe(false);
  });

  it('directory entries 不匹配时 fail-closed', () => {
    const manifest = makeManifest({
      generatedFiles: [
        { path: 'icons/', kind: 'directory', entries: 2 },
        { path: 'icons/a.png', sha256: `sha256:${'a'.repeat(64)}`, size: 1 },
      ],
    });
    const probe = makeProbe({
      fileSha256: () => `sha256:${'a'.repeat(64)}`,
      fileSize: () => 1,
    });
    expect(validateCatalogManifest(manifest, [makeItem()], '', probe)).toBe(false);
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
    const probe = makeProbe({
      fileExists: (path) => path !== 'icons/ui/icon_x.png',
    });
    expect(validateCatalogManifest(manifest, [item], '', probe)).toBe(false);
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
    expect(validateCatalogManifest(makeManifest(), [item], '', makeProbe())).toBe(false);
  });

  it('AssetRef neither-present 时 fail-closed', () => {
    const item: CatalogItem = {
      ...makeItem(),
      icon: {
        container: 'sc/ui.sc',
        exportName: 'icon_x',
        renderedPath: null,
        missingReason: null,
      },
    };
    expect(validateCatalogManifest(makeManifest(), [item], '', makeProbe())).toBe(false);
  });
});
