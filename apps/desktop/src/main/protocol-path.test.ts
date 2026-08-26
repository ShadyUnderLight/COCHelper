import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { resolveRendererAsset } from './protocol-path';

describe('resolveRendererAsset', () => {
  const root = path.resolve('/tmp/cochelper-renderer');

  it('把 / 映射到 index.html', () => {
    expect(resolveRendererAsset(root, '/')).toBe(path.join(root, 'index.html'));
  });

  it('消化 webpack 的 /main_window 公共路径', () => {
    expect(resolveRendererAsset(root, '/main_window/index.js')).toBe(path.join(root, 'index.js'));
    expect(resolveRendererAsset(root, '/main_window')).toBe(path.join(root, 'index.html'));
  });

  it('拒绝路径穿越', () => {
    expect(resolveRendererAsset(root, '/../../etc/passwd')).toBeNull();
    expect(resolveRendererAsset(root, '/%2e%2e/%2e%2e/etc/passwd')).toBeNull();
  });

  it('拒绝 NUL', () => {
    expect(resolveRendererAsset(root, '/index.html\0.js')).toBeNull();
  });
});
