/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { TokenSettingsPanel } from './TokenSettingsPanel';

describe('TokenSettingsPanel', () => {
  afterEach(() => {
    cleanup();
  });

  it('保存成功后清空局部输入框，不回显 token', async () => {
    const tokenSave = vi.fn(async () => ({
      ok: true as const,
      value: { configured: true, storage: 'available' as const, message: null },
    }));
    const bridge = {
      tokenStatus: vi.fn(async () => ({
        ok: true as const,
        value: { configured: false, storage: 'available' as const, message: null },
      })),
      tokenSave,
      tokenClear: vi.fn(async () => ({
        ok: true as const,
        value: { configured: false, storage: 'available' as const, message: null },
      })),
    };

    render(<TokenSettingsPanel bridge={bridge} />);
    await waitFor(() => expect(screen.getByText('当前未配置 Token。')).toBeTruthy());

    const input = screen.getByLabelText('CoC API Token') as HTMLInputElement;
    fireEvent.change(input, { target: { value: 'secret-token' } });
    fireEvent.click(screen.getByRole('button', { name: '保存 Token' }));

    await waitFor(() => expect(tokenSave).toHaveBeenCalledWith({ token: 'secret-token' }));
    await waitFor(() => expect(input.value).toBe(''));
    expect(document.body.textContent).not.toContain('secret-token');
  });

  it('安全存储不可用时禁用保存', async () => {
    const bridge = {
      tokenStatus: vi.fn(async () => ({
        ok: true as const,
        value: {
          configured: false,
          storage: 'unavailable' as const,
          message: '系统安全存储不可用。',
        },
      })),
      tokenSave: vi.fn(),
      tokenClear: vi.fn(),
    };

    render(<TokenSettingsPanel bridge={bridge} />);
    await waitFor(() => expect(screen.getByText(/安全存储不可用/)).toBeTruthy());
    expect(screen.getByRole('button', { name: '保存 Token' })).toHaveProperty('disabled', true);
    expect(bridge.tokenSave).not.toHaveBeenCalled();
  });
});
