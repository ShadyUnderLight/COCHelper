import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

const css = readFileSync(join(__dirname, '../renderer/styles.css'), 'utf8');

type RgbColor = {
  readonly red: number;
  readonly green: number;
  readonly blue: number;
  readonly alpha: number;
};

function declaration(selector: string, property: string): string {
  const blocks = Array.from(css.matchAll(new RegExp('([^{}]+)\\{([^{}]+)\\}', 'g')));
  for (const block of blocks) {
    const selectors = block[1]?.split(',').map((candidate) => candidate.trim());
    if (!selectors?.includes(selector) || block[2] === undefined) {
      continue;
    }
    const match = block[2].match(new RegExp(property + '\\s*:\\s*([^;]+)'));
    if (match?.[1] !== undefined) {
      return match[1].trim();
    }
  }
  throw new Error('找不到 ' + selector + ' 的 ' + property);
}

function colorStops(selector: string, property: string): readonly string[] {
  const stops = declaration(selector, property).match(/#[0-9a-fA-F]{6}/g);
  if (stops === null || stops.length === 0) {
    throw new Error('找不到 ' + selector + ' 的 ' + property + ' 色值');
  }
  return stops;
}

function parseColor(value: string): RgbColor {
  const hex = value.match(/^#([0-9a-fA-F]{6})$/);
  if (hex?.[1] !== undefined) {
    const channels = Number.parseInt(hex[1], 16);
    return {
      red: (channels >> 16) & 255,
      green: (channels >> 8) & 255,
      blue: channels & 255,
      alpha: 1,
    };
  }

  const rgb = value.match(/^rgb\(\s*(\d+)\s+(\d+)\s+(\d+)(?:\s*\/\s*([\d.]+%?))?\s*\)$/);
  if (rgb?.[1] === undefined || rgb[2] === undefined || rgb[3] === undefined) {
    throw new Error('无法解析颜色：' + value);
  }
  const alphaValue = rgb[4];
  const alpha =
    alphaValue === undefined
      ? 1
      : alphaValue.endsWith('%')
        ? Number.parseFloat(alphaValue) / 100
        : Number.parseFloat(alphaValue);
  return {
    red: Number(rgb[1]),
    green: Number(rgb[2]),
    blue: Number(rgb[3]),
    alpha,
  };
}

function compositeColor(foreground: RgbColor, background: RgbColor): RgbColor {
  const alpha = foreground.alpha + background.alpha * (1 - foreground.alpha);
  const channel = (front: number, behind: number): number =>
    alpha === 0
      ? 0
      : (front * foreground.alpha + behind * background.alpha * (1 - foreground.alpha)) / alpha;
  return {
    red: channel(foreground.red, background.red),
    green: channel(foreground.green, background.green),
    blue: channel(foreground.blue, background.blue),
    alpha,
  };
}

function backgroundSamples(selector: string, parentSelector?: string): readonly RgbColor[] {
  const background = declaration(selector, 'background');
  const hexStops = background.match(/#[0-9a-fA-F]{6}/g);
  const colors = hexStops?.map(parseColor) ?? [parseColor(background)];
  return colors.flatMap((color) => {
    if (color.alpha === 1) {
      return [color];
    }
    if (parentSelector === undefined) {
      throw new Error(selector + ' uses a translucent background without a parent surface');
    }
    return backgroundSamples(parentSelector).map((parent) => compositeColor(color, parent));
  });
}

function linearChannel(value: number): number {
  const channel = value / 255;
  return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
}

function relativeLuminance(value: string | RgbColor): number {
  const color = typeof value === 'string' ? parseColor(value) : value;
  return (
    0.2126 * linearChannel(color.red) +
    0.7152 * linearChannel(color.green) +
    0.0722 * linearChannel(color.blue)
  );
}

function contrastRatio(foreground: string | RgbColor, background: string | RgbColor): number {
  const backgroundColor = typeof background === 'string' ? parseColor(background) : background;
  const foregroundColor = typeof foreground === 'string' ? parseColor(foreground) : foreground;
  const opaqueForeground =
    foregroundColor.alpha === 1
      ? foregroundColor
      : compositeColor(foregroundColor, backgroundColor);
  const a = relativeLuminance(opaqueForeground);
  const b = relativeLuminance(backgroundColor);
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

describe('升级总览小字对比度', () => {
  it('默认与选中记录、统计卡和区块说明至少 4.5:1', () => {
    const cases: ReadonlyArray<readonly [string, string, string, string?]> = [
      ['.overview-item-meta', '.overview-item', '默认升级记录'],
      ['.overview-item-meta', '.overview-item.selected', '选中升级记录'],
      ['.card-heading p', '.content-card', '区块说明'],
      ['.stat-top', '.stat-card', '统计标签'],
      ['.stat-value small', '.stat-card', '统计单位'],
      ['.section-eyebrow', '.preview-box', '内容区小标题'],
      ['.preview-facts span', '.preview-facts p', '导入预览字段标签', '.preview-box'],
      ['.preview-diagnostic', '.preview-box', '导入预览诊断文字'],
      ['.metric-card .muted', '.metric-card', '详情指标说明'],
      ['.diagnostic-row dt', '.diagnostics-sections section', '诊断字段标签', '.info-panel'],
      ['.status-technical', '.status-technical', '侧栏技术信息'],
      ['.record-badge', '.record-badge', '记录数量'],
      ['.empty-state.compact', '.content-card', '空态说明'],
      ['.quiet-card p', '.quiet-card', '无待处理说明'],
    ];
    for (const [foregroundSelector, backgroundSelector, label, parentSelector] of cases) {
      const foreground = parseColor(declaration(foregroundSelector, 'color'));
      for (const background of backgroundSamples(backgroundSelector, parentSelector)) {
        expect(
          contrastRatio(foreground, background),
          label + ' contrast on ' + JSON.stringify(background),
        ).toBeGreaterThanOrEqual(4.5);
      }
    }
  });
});
