import { describe, expect, it } from 'vitest';

import type { CatalogAssetRefDto } from '@coc-helper/contracts';

import { overviewAssetUrl } from './asset-url';

function ref(overrides: Partial<CatalogAssetRefDto> = {}): CatalogAssetRefDto {
  return {
    container: 'sc/buildings.sc',
    exportName: 'xbow',
    renderedPath: 'icons/buildings/BB_xbow_lvl1.png',
    missingReason: null,
    ...overrides,
  };
}

describe('overviewAssetUrl', () => {
  it('与 main catalog-service 同构（含 parity 用例）', () => {
    expect(overviewAssetUrl('18.400.13', ref())).toBe(
      'cochelper://catalog/18.400.13/icons/buildings/BB_xbow_lvl1.png',
    );
  });
  it('version 缺失返回 null', () => {
    expect(overviewAssetUrl(null, ref())).toBeNull();
    expect(overviewAssetUrl('', ref())).toBeNull();
  });
  it('ref 缺失返回 null', () => {
    expect(overviewAssetUrl('18.400.13', null)).toBeNull();
  });
  it('renderedPath 空返回 null', () => {
    expect(overviewAssetUrl('18.400.13', ref({ renderedPath: null }))).toBeNull();
    expect(overviewAssetUrl('18.400.13', ref({ renderedPath: '' }))).toBeNull();
  });
  it('missingReason 非空返回 null（不可渲染原样暴露，不拼 URL）', () => {
    expect(overviewAssetUrl('18.400.13', ref({ missingReason: 'icons_not_rendered' }))).toBeNull();
  });
  it('路径穿越与绝对路径返回 null', () => {
    expect(overviewAssetUrl('18.400.13', ref({ renderedPath: '../secret.png' }))).toBeNull();
    expect(overviewAssetUrl('18.400.13', ref({ renderedPath: 'a/../../b.png' }))).toBeNull();
    expect(overviewAssetUrl('18.400.13', ref({ renderedPath: '/etc/passwd' }))).toBeNull();
  });
});
