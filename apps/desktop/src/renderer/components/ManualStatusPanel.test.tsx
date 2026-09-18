/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { ManualStatePayload } from '@coc-helper/contracts';

import { type ManualView } from '../manual-session';
import { ManualStatusPanel } from './ManualStatusPanel';

function availablePayload(overrides: Partial<ManualStatePayload> = {}): ManualStatePayload {
  return {
    generation: 5,
    villageId: 'v1',
    status: 'available',
    error: null,
    baselineRevision: 'rev',
    baselineLineageId: 'line',
    activeRecordCount: 1,
    itemStateCount: 1,
    activeRecords: [
      {
        recordId: '00000000-0000-4000-8000-000000000001',
        status: 'active',
        fromLevel: 5,
        targetLevel: 6,
        quantity: 1,
        startedAtMs: 1_000,
        expectedEndAtMs: 2_000,
      },
    ],
    lastSettleAtMs: null,
    lastImportAtMs: 1_000,
    stateUpdatedAtMs: 1_000,
    ...overrides,
  };
}

function readyView(overrides: Partial<ManualView> = {}): ManualView {
  return {
    status: 'ready',
    payload: availablePayload(),
    lastError: null,
    queryStale: false,
    ...overrides,
  };
}

function baseProps() {
  return {
    canWrite: true,
    busy: false,
    commandError: null as string | null,
    onRetry: vi.fn(),
    onSettle: vi.fn(),
    onCancelRecord: vi.fn(),
    onAdjustRecord: vi.fn(),
  };
}

afterEach(() => {
  cleanup();
});

describe('ManualStatusPanel', () => {
  it('loading 显示加载文案', () => {
    render(
      <ManualStatusPanel
        view={{ status: 'loading', payload: null, lastError: null, queryStale: false }}
        {...baseProps()}
      />,
    );
    expect(screen.getByText('正在加载手动升级状态…')).toBeTruthy();
  });

  it('error 显示错误与重试', () => {
    const onRetry = vi.fn();
    render(
      <ManualStatusPanel
        view={{ status: 'error', payload: null, lastError: '加载失败', queryStale: false }}
        {...baseProps()}
        onRetry={onRetry}
      />,
    );
    expect(screen.getByRole('alert').textContent).toMatch(/加载失败/);
    fireEvent.click(screen.getByText('重试'));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it('queryStale 时禁用写操作按钮', () => {
    render(
      <ManualStatusPanel
        view={readyView({ queryStale: true, lastError: '数据可能过期' })}
        {...baseProps()}
      />,
    );
    expect((screen.getByText('结算到期升级') as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByText('取消') as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByText('调整开始时间') as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByText('刷新状态') as HTMLButtonElement).disabled).toBe(false);
  });

  it('只读模式禁用写操作', () => {
    render(<ManualStatusPanel view={readyView()} {...baseProps()} canWrite={false} />);
    expect((screen.getByText('结算到期升级') as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByText('取消') as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByText('调整开始时间') as HTMLButtonElement).disabled).toBe(true);
  });

  it('可写时结算与记录操作可点击', () => {
    const onSettle = vi.fn();
    const onCancelRecord = vi.fn();
    const onAdjustRecord = vi.fn();
    render(
      <ManualStatusPanel
        view={readyView()}
        {...baseProps()}
        onSettle={onSettle}
        onCancelRecord={onCancelRecord}
        onAdjustRecord={onAdjustRecord}
      />,
    );
    fireEvent.click(screen.getByText('结算到期升级'));
    fireEvent.click(screen.getByText('取消'));
    fireEvent.click(screen.getByText('调整开始时间'));
    expect(onSettle).toHaveBeenCalledTimes(1);
    expect(onCancelRecord).toHaveBeenCalledWith('00000000-0000-4000-8000-000000000001');
    expect(onAdjustRecord).toHaveBeenCalledWith('00000000-0000-4000-8000-000000000001', 1_000);
  });

  it('commandError 与 stale 提示可见', () => {
    render(
      <ManualStatusPanel
        view={readyView({ queryStale: true, lastError: '命令结果未知，正在同步状态…' })}
        {...baseProps()}
        commandError="IPC 通道异常"
      />,
    );
    expect(screen.getByText(/IPC 通道异常/)).toBeTruthy();
    expect(screen.getByText(/数据可能过期/)).toBeTruthy();
    expect(screen.getByText(/命令结果未知/)).toBeTruthy();
  });
});
