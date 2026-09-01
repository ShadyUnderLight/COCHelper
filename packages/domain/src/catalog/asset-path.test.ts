import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { renderedPathFormatOk, resolveCatalogAssetPath } from './asset-path';

describe('renderedPathFormatOk', () => {
  it('接受合法 icons 路径', () => {
    expect(renderedPathFormatOk('icons/buildings/tower.png')).toBe(true);
  });

  it('拒绝 ..、绝对路径和版本段', () => {
    expect(renderedPathFormatOk('icons/../tower.png')).toBe(false);
    expect(renderedPathFormatOk('/icons/buildings/tower.png')).toBe(false);
    expect(renderedPathFormatOk('icons/18.400.13/tower.png')).toBe(false);
    expect(renderedPathFormatOk('')).toBe(false);
    expect(renderedPathFormatOk('icons/ui/%2e%2e.png')).toBe(false);
  });
});

describe('resolveCatalogAssetPath', () => {
  const root = resolve('/tmp/coc-catalog');

  it('解析 version 前缀下的 PNG', () => {
    expect(resolveCatalogAssetPath(root, '18.400.13', '/18.400.13/icons/ui/icon_x.png')).toBe(
      resolve(root, '18.400.13/icons/ui/icon_x.png'),
    );
  });

  it('拒绝路径穿越和非法协议路径', () => {
    expect(resolveCatalogAssetPath(root, '18.400.13', '/18.400.13/../../etc/passwd')).toBeNull();
    expect(resolveCatalogAssetPath(root, '18.400.13', '/99.0.0/icons/ui/icon_x.png')).toBeNull();
    expect(resolveCatalogAssetPath(root, '18.400.13', '/18.400.13/not-icons/x.png')).toBeNull();
  });
});
