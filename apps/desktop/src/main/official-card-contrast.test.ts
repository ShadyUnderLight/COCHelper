import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

const css = readFileSync(join(__dirname, '../renderer/styles.css'), 'utf8');

function declaration(selector: string, property: string): string {
  const escaped = selector.replace(/[.*+?^$()|[\]\\]/g, '\\$&');
  const block = css.match(new RegExp('(?:^|\\n)\\s*' + escaped + '\\s*\\{([^}]+)\\}'));
  if (block === null) {
    throw new Error('找不到选择器 ' + selector);
  }
  const match = block[1]?.match(new RegExp(property + '\\s*:\\s*([^;]+)'));
  if (match?.[1] === undefined) {
    throw new Error('找不到 ' + selector + ' 的 ' + property);
  }
  return match[1].trim();
}

function colorStops(selector: string, property: string): readonly string[] {
  const stops = declaration(selector, property).match(/#[0-9a-fA-F]{6}/g);
  if (stops === null || stops.length === 0) {
    throw new Error('找不到 ' + selector + ' 的 ' + property + ' 色值');
  }
  return stops;
}

function linearChannel(value: number): number {
  const channel = value / 255;
  return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
}

function relativeLuminance(hex: string): number {
  const n = Number.parseInt(hex.slice(1), 16);
  const r = (n >> 16) & 255;
  const g = (n >> 8) & 255;
  const b = n & 255;
  return 0.2126 * linearChannel(r) + 0.7152 * linearChannel(g) + 0.0722 * linearChannel(b);
}

function contrastRatio(foreground: string, background: string): number {
  const a = relativeLuminance(foreground);
  const b = relativeLuminance(background);
  const [hi, lo] = a > b ? [a, b] : [b, a];
  return (hi + 0.05) / (lo + 0.05);
}

describe('Official 卡片对比度（#277）', () => {
  it('Official 卡上的状态色在渐变每个色阶至少 4.5:1', () => {
    const backgrounds = colorStops('.official-card', 'background');
    expect(backgrounds.length).toBeGreaterThan(1);
    const pairs: ReadonlyArray<readonly [string, string]> = [
      ['.official-source', 'color'],
      ['.official-card .error-text', 'color'],
      ['.muted', 'color'],
      ['.notice-text', 'color'],
      ['.official-ok', 'color'],
    ];
    for (const [selector, property] of pairs) {
      const foreground = declaration(selector, property);
      for (const background of backgrounds) {
        expect(
          contrastRatio(foreground, background),
          selector + ' contrast on ' + background,
        ).toBeGreaterThanOrEqual(4.5);
      }
    }
  });
});
