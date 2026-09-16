import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

const css = readFileSync(join(__dirname, '../renderer/styles.css'), 'utf8');

function declaration(selector: string, property: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const block = css.match(new RegExp(`${escaped}\\s*\\{([^}]+)\\}`));
  if (block === null) {
    throw new Error(`找不到选择器 ${selector}`);
  }
  const match = block[1]?.match(new RegExp(`${property}\\s*:\\s*(#[0-9a-fA-F]{6})`));
  if (match?.[1] === undefined) {
    throw new Error(`找不到 ${selector} 的 ${property}`);
  }
  return match[1];
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
  it('.official-source 与 .official-card 上的 error-text 至少 4.5:1', () => {
    const background = declaration('.official-card', 'background');
    const source = declaration('.official-source', 'color');
    const error = declaration('.official-card .error-text', 'color');
    expect(contrastRatio(source, background)).toBeGreaterThanOrEqual(4.5);
    expect(contrastRatio(error, background)).toBeGreaterThanOrEqual(4.5);
  });
});
