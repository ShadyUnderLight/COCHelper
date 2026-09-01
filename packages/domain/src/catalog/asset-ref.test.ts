import { describe, expect, it } from 'vitest';

import {
  isCatalogAssetRefSemanticallyValid,
  isCatalogAssetRenderable,
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

describe('CatalogAssetRef semantics', () => {
  it('接受 renderable 与 missing 两种合法状态', () => {
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

  it('拒绝 both-present 与 neither-present', () => {
    expect(
      isCatalogAssetRefSemanticallyValid(
        ref({ renderedPath: 'icons/ui/x.png', missingReason: 'export_not_found' }),
      ),
    ).toBe(false);
    expect(
      isCatalogAssetRefSemanticallyValid(ref({ renderedPath: null, missingReason: null })),
    ).toBe(false);
    expect(isCatalogAssetRefSemanticallyValid(ref({ renderedPath: '', missingReason: null }))).toBe(
      false,
    );
  });

  it('isCatalogAssetRenderable 与语义 invariant 一致', () => {
    expect(
      isCatalogAssetRenderable(ref({ renderedPath: 'icons/ui/x.png', missingReason: null })),
    ).toBe(true);
    expect(
      isCatalogAssetRenderable(ref({ renderedPath: 'icons/ui/x.png', missingReason: 'x' })),
    ).toBe(false);
    expect(
      isCatalogAssetRenderable(ref({ renderedPath: null, missingReason: 'icons_not_rendered' })),
    ).toBe(false);
  });

  it('validateCatalogItemsAssetRefs 扫描 item/level refs', () => {
    const validItem: CatalogItem = {
      section: 'units',
      category: 'troops',
      dataID: 1n,
      base: 'home',
      baseMissingReason: null,
      name: 'x',
      maxLevel: 1,
      icon: ref({ renderedPath: 'icons/ui/x.png', missingReason: null }),
      levelVisual: null,
      missingReason: null,
      displayCategory: null,
      lifecycle: null,
      levels: [],
    };
    expect(validateCatalogItemsAssetRefs([validItem])).toBe(true);
    expect(
      validateCatalogItemsAssetRefs([
        {
          ...validItem,
          icon: ref({ renderedPath: 'icons/ui/x.png', missingReason: 'export_not_found' }),
        },
      ]),
    ).toBe(false);
  });
});
