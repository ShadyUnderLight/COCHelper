import { describe, expect, it } from 'vitest';

import { diagnosticsApplicationLabel, diagnosticsResourceErrorText } from './diagnostics-session';

describe('diagnostics-session', () => {
  it('为全局 availability 提供独立文案', () => {
    expect(diagnosticsApplicationLabel('available')).toBe('可用');
    expect(diagnosticsApplicationLabel('recovery')).toBe('需要恢复');
    expect(diagnosticsApplicationLabel('unavailable')).toBe('不可用');
  });

  it('区分初次失败和保留 last-good 的失败', () => {
    expect(
      diagnosticsResourceErrorText({
        kind: 'failed',
        data: null,
        error: { message: '连接失败' },
      }),
    ).toBe('诊断加载失败：连接失败');
    expect(
      diagnosticsResourceErrorText({
        kind: 'failedWithLastGood',
        data: {} as never,
        error: { message: '刷新失败' },
      }),
    ).toBe('诊断刷新失败，已保留上次成功诊断：刷新失败');
  });
});
