import { describe, expect, it } from 'vitest';

import {
  isCatalogAssetRefNoReference,
  isCatalogAssetRefSemanticallyValid,
  isCatalogAssetRenderable,
  validateCatalogAssetRefContract,
  validateCatalogItemsAssetRefs,
} from './asset-ref';
import type { CatalogAssetRef, CatalogItem } from './types';

function ref(partial: Partial<CatalogAssetRef>): CatalogAssetRef {
  return {
    container: null,
    exportName: null,
    renderedPath: null,
    missingReason: null,
    ...partial,
  };
}

describe('CatalogAssetRef contract', () => {
  it('R-A：null/null 是合法 no-reference', () => {
    expect(isCatalogAssetRefNoReference(ref({ renderedPath: null, missingReason: null }))).toBe(
      true,
    );
    expect(
      isCatalogAssetRefSemanticallyValid(ref({ renderedPath: null, missingReason: null })),
    ).toBe(true);
    expect(
      validateCatalogItemsAssetRefs([makeItem(ref({ renderedPath: null, missingReason: null }))]),
    ).toBe(true);
  });

  it('R-B：path + missingReason 空串仍拒绝', () => {
    expect(
      isCatalogAssetRefSemanticallyValid(
        ref({ renderedPath: 'icons/ui/foo.png', missingReason: '' }),
      ),
    ).toBe(false);
    expect(
      isCatalogAssetRefSemanticallyValid(
        ref({ renderedPath: 'icons/ui/foo.png', missingReason: 'export_not_found' }),
      ),
    ).toBe(false);
  });

  it('renderable 与 missing 两种合法状态', () => {
    expect(
      isCatalogAssetRefSemanticallyValid(
        ref({ renderedPath: 'icons/ui/x.png', missingReason: null }),
      ),
    ).toBe(true);
    expect(
      isCatalogAssetRefSemanticallyValid(
        ref({ renderedPath: null, missingReason: 'export_not_found' }),
      ),
    ).toBe(true);
  });

  it('R-D：非法 path 拒绝', () => {
    expect(
      isCatalogAssetRefSemanticallyValid(
        ref({ renderedPath: '../outside.png', missingReason: null }),
      ),
    ).toBe(false);
    expect(
      isCatalogAssetRefSemanticallyValid(
        ref({ renderedPath: 'icons/18.400.13/x.png', missingReason: null }),
      ),
    ).toBe(false);
  });

  it('R-C：存在但未登记的路径拒绝', () => {
    const registered = new Set(['icons/ui/x.png']);
    expect(
      validateCatalogAssetRefContract(
        ref({ renderedPath: 'icons/ui/y.png', missingReason: null }),
        registered,
        () => true,
      ),
    ).toBe(false);
    expect(
      validateCatalogAssetRefContract(
        ref({ renderedPath: 'icons/ui/x.png', missingReason: null }),
        registered,
        () => true,
      ),
    ).toBe(true);
  });

  it('isCatalogAssetRenderable 与 contract 一致', () => {
    expect(
      isCatalogAssetRenderable(ref({ renderedPath: 'icons/ui/x.png', missingReason: null })),
    ).toBe(true);
    expect(isCatalogAssetRenderable(ref({ renderedPath: null, missingReason: null }))).toBe(false);
    expect(
      isCatalogAssetRenderable(ref({ renderedPath: 'icons/ui/x.png', missingReason: '' })),
    ).toBe(false);
  });
});

function makeItem(icon: CatalogAssetRef): CatalogItem {
  return {
    section: 'units',
    category: 'troops',
    dataID: 1n,
    base: 'home',
    baseMissingReason: null,
    name: 'x',
    maxLevel: 1,
    icon,
    levelVisual: null,
    missingReason: null,
    displayCategory: null,
    lifecycle: null,
    levels: [],
  };
}
