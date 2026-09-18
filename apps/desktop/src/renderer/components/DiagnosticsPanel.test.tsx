/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { resourceFailure, resourceSuccess } from '../resource-state';
import { DiagnosticsPanel } from './DiagnosticsPanel';

const payload = {
  sessionId: 'session-1',
  app: { name: 'COCHelper', version: '0.0.0' },
  runtime: {
    electron: '44.0.0',
    node: '24.18.1',
    chrome: '136.0.0',
    platform: 'darwin',
    arch: 'arm64',
  },
  application: {
    availability: 'available' as const,
    villageStatus: 'available' as const,
    generation: 2,
    selectedVillageId: 'v1',
    selectedVillageName: '主村',
    canWrite: true,
    hasPendingJournal: false,
  },
  catalog: { status: 'available' as const, version: '18.400.13' },
  official: {
    endpointAccess: 'mainOnly' as const,
    authorization: 'mainOnly' as const,
    credentialStorage: 'available' as const,
    rawResponseExposure: 'notExposed' as const,
  },
  manual: { status: 'empty' as const },
  token: { configured: false, storage: 'available' as const, message: null },
};

describe('DiagnosticsPanel', () => {
  afterEach(() => {
    cleanup();
  });

  it('展示安全诊断字段和空 Token 状态', () => {
    render(<DiagnosticsPanel state={resourceSuccess(payload)} onRetry={() => undefined} />);
    expect(screen.getByText('COCHelper')).toBeTruthy();
    expect(screen.getByText('当前村庄')).toBeTruthy();
    expect(screen.getByText('未配置')).toBeTruthy();
    expect(screen.getByText('仅由 Main 进程访问')).toBeTruthy();
  });

  it('失败但有 last-good 时保留数据并显示独立文案', () => {
    const onRetry = vi.fn();
    render(
      <DiagnosticsPanel
        state={resourceFailure(resourceSuccess(payload), '刷新失败')}
        onRetry={onRetry}
      />,
    );
    expect(screen.getByText(/已保留上次成功诊断/)).toBeTruthy();
    expect(screen.getByText('COCHelper')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: '刷新诊断' }));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });
});
