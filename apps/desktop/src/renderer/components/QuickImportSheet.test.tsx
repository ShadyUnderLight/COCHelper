/** @vitest-environment jsdom */

import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { QuickImportPreviewWire } from '@coc-helper/contracts';

import type { QuickImportState } from '../use-quick-import';
import { QuickImportSheet } from './QuickImportSheet';

function preview(): QuickImportPreviewWire {
  return {
    snapshot: {
      importedAt: 1,
      originalText: '{"tag":"#QA","buildings":[]}',
      objectSections: {},
      numericSections: {},
      boosts: {},
      unknownTopLevelKeys: ['extra'],
      diagnostics: [{ id: 'd1', severity: 'info', path: '$.tag', message: 'ok' }],
    },
    targetVillageId: 'v-a',
    targetVillageName: 'A',
    targetVillageTag: '#QA',
    targetVillageHasSnapshot: true,
    replacesSameTag: true,
    destinationDescription: '导入目标：按当前详情页更新「A」',
  };
}

function state(overrides: Partial<QuickImportState> = {}): QuickImportState {
  return {
    status: 'idle',
    targetVillageId: null,
    preview: null,
    preparedGeneration: null,
    lastError: null,
    ...overrides,
  };
}

afterEach(() => {
  cleanup();
});

describe('QuickImportSheet', () => {
  it('ready 时展示目标对照与诊断，确认可用', () => {
    const onConfirm = vi.fn();
    render(
      <QuickImportSheet
        state={state({
          status: 'ready',
          targetVillageId: 'v-a',
          preview: preview(),
          preparedGeneration: 8,
        })}
        canWrite
        onConfirm={onConfirm}
        onCancel={vi.fn()}
        onRetry={vi.fn()}
        onClose={vi.fn()}
      />,
    );
    expect(screen.getByText(/目标村庄「A」/)).toBeTruthy();
    expect(screen.getByText(/按当前详情页更新/)).toBeTruthy();
    expect(screen.getByText(/诊断 1 条/)).toBeTruthy();
    const confirm = screen.getByRole('button', { name: '确认导入' });
    expect((confirm as HTMLButtonElement).disabled).toBe(false);
  });

  it('stale 时禁用确认并提供重新预览', () => {
    render(
      <QuickImportSheet
        state={{
          status: 'ready',
          targetVillageId: 'v-a',
          preview: preview(),
          preparedGeneration: 8,
          lastError: '导入状态已变化，请重新粘贴并更新。',
        }}
        canWrite
        onConfirm={vi.fn()}
        onCancel={vi.fn()}
        onRetry={vi.fn()}
        onClose={vi.fn()}
      />,
    );
    expect((screen.getByRole('button', { name: '确认导入' }) as HTMLButtonElement).disabled).toBe(
      true,
    );
    expect(screen.getByRole('button', { name: '重新预览' })).toBeTruthy();
    expect(screen.getByRole('alert')).toBeTruthy();
  });

  it('只读时确认禁用', () => {
    render(
      <QuickImportSheet
        state={{
          status: 'ready',
          targetVillageId: 'v-a',
          preview: preview(),
          preparedGeneration: 8,
          lastError: null,
        }}
        canWrite={false}
        onConfirm={vi.fn()}
        onCancel={vi.fn()}
        onRetry={vi.fn()}
        onClose={vi.fn()}
      />,
    );
    expect((screen.getByRole('button', { name: '确认导入' }) as HTMLButtonElement).disabled).toBe(
      true,
    );
  });

  it('失败态展示错误与重试', () => {
    render(
      <QuickImportSheet
        state={{
          status: 'idle',
          targetVillageId: 'v-a',
          preview: null,
          preparedGeneration: null,
          lastError: '系统剪贴板中没有可用的文本。',
        }}
        canWrite
        onConfirm={vi.fn()}
        onCancel={vi.fn()}
        onRetry={vi.fn()}
        onClose={vi.fn()}
      />,
    );
    expect(screen.getByRole('alert').textContent).toBe('系统剪贴板中没有可用的文本。');
    expect(screen.getByRole('button', { name: '重试' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: '确认导入' })).toBeNull();
  });

  it('准备中展示 loading 且按钮禁用', () => {
    render(
      <QuickImportSheet
        state={{
          status: 'preparing',
          targetVillageId: 'v-a',
          preview: null,
          preparedGeneration: null,
          lastError: null,
        }}
        canWrite
        onConfirm={vi.fn()}
        onCancel={vi.fn()}
        onRetry={vi.fn()}
        onClose={vi.fn()}
      />,
    );
    expect(screen.getByText(/正在读取剪贴板/)).toBeTruthy();
    expect((screen.getByRole('button', { name: '关闭' }) as HTMLButtonElement).disabled).toBe(true);
  });
});
