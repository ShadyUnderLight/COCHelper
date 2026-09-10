/** @vitest-environment jsdom */

import { cleanup, fireEvent, render } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';

import { AssetImage } from './AssetImage';

afterEach(() => {
  cleanup();
});

function ref(path: string) {
  return { container: 'sc', exportName: path, renderedPath: path, missingReason: null } as const;
}

describe('AssetImage（#277-C2 review）', () => {
  it('首选首个 URL', () => {
    const { container } = render(
      <AssetImage
        catalogVersion="18.400.13"
        candidates={[ref('icons/a.png'), ref('icons/b.png')]}
        size={28}
        className="overview-item-icon"
        fallbackNode={null}
      />,
    );
    expect(container.querySelector('img')?.getAttribute('src')).toBe(
      'cochelper://catalog/18.400.13/icons/a.png',
    );
  });

  it('onError 推进到第二个候选', () => {
    const { container } = render(
      <AssetImage
        catalogVersion="18.400.13"
        candidates={[ref('icons/a.png'), ref('icons/b.png')]}
        size={28}
        className="overview-item-icon"
        fallbackNode={null}
      />,
    );
    const first = container.querySelector('img');
    expect(first).not.toBeNull();
    fireEvent.error(first!);
    expect(container.querySelector('img')?.getAttribute('src')).toBe(
      'cochelper://catalog/18.400.13/icons/b.png',
    );
  });

  it('全部失败 hide → null（容器空）', () => {
    const { container } = render(
      <AssetImage
        catalogVersion="v"
        candidates={[ref('icons/a.png')]}
        size={28}
        className="overview-item-icon"
        fallbackNode={null}
      />,
    );
    const img = container.querySelector('img');
    expect(img).not.toBeNull();
    fireEvent.error(img!);
    expect(container.querySelector('img')).toBeNull();
    expect(container.textContent).toBe('');
  });

  it('全部失败 placeholder → 图标缺失', () => {
    const { container } = render(
      <AssetImage
        catalogVersion="v"
        candidates={[ref('icons/a.png')]}
        size={40}
        className="item-icon"
        fallbackNode={<span>图标缺失</span>}
      />,
    );
    const img = container.querySelector('img');
    expect(img).not.toBeNull();
    fireEvent.error(img!);
    expect(container.querySelector('img')).toBeNull();
    expect(container.textContent).toContain('图标缺失');
  });

  it('候选/version 变化重置到首个（P2-3 回归）', () => {
    const { container, rerender } = render(
      <AssetImage
        catalogVersion="v1"
        candidates={[ref('icons/a.png'), ref('icons/b.png')]}
        size={28}
        className="overview-item-icon"
        fallbackNode={null}
      />,
    );
    fireEvent.error(container.querySelector('img')!);
    expect(container.querySelector('img')?.getAttribute('src')).toContain('icons/b.png');
    rerender(
      <AssetImage
        catalogVersion="v1"
        candidates={[ref('icons/c.png'), ref('icons/d.png')]}
        size={28}
        className="overview-item-icon"
        fallbackNode={null}
      />,
    );
    expect(container.querySelector('img')?.getAttribute('src')).toBe(
      'cochelper://catalog/v1/icons/c.png',
    );
  });

  it('空候选立即 fallback', () => {
    const { container } = render(
      <AssetImage catalogVersion="v" candidates={[]} size={28} className="x" fallbackNode={null} />,
    );
    expect(container.querySelector('img')).toBeNull();
  });
});
