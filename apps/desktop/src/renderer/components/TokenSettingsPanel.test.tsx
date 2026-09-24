/** @vitest-environment jsdom */

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { TOKEN_MAX_LENGTH } from '@coc-helper/contracts';

import { TokenSettingsPanel } from './TokenSettingsPanel';

describe('TokenSettingsPanel', () => {
  afterEach(() => {
    cleanup();
  });

  it('保存成功后清空局部输入框，不回显 token', async () => {
    const token = 'x'.repeat(564);
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

    const onTokenChanged = vi.fn();
    render(<TokenSettingsPanel bridge={bridge} onTokenChanged={onTokenChanged} />);
    await waitFor(() => expect(screen.getByText('当前未配置 Token。')).toBeTruthy());

    const input = screen.getByLabelText('CoC API Token') as HTMLInputElement;
    fireEvent.change(input, { target: { value: `  ${token}  ` } });
    fireEvent.click(screen.getByRole('button', { name: '保存 Token' }));

    await waitFor(() => expect(tokenSave).toHaveBeenCalledWith({ token }));
    await waitFor(() => expect(input.value).toBe(''));
    expect(onTokenChanged).toHaveBeenCalledTimes(1);
    expect(document.body.textContent).not.toContain(token);
  });

  it('拒绝超出 IPC 上限的 token，并显示长度错误', async () => {
    const tokenSave = vi.fn();
    const bridge = {
      tokenStatus: vi.fn(async () => ({
        ok: true as const,
        value: { configured: false, storage: 'available' as const, message: null },
      })),
      tokenSave,
      tokenClear: vi.fn(),
    };

    render(<TokenSettingsPanel bridge={bridge} />);
    await waitFor(() => expect(screen.getByText('当前未配置 Token。')).toBeTruthy());

    const input = screen.getByLabelText('CoC API Token') as HTMLInputElement;
    fireEvent.change(input, { target: { value: 'x'.repeat(TOKEN_MAX_LENGTH + 1) } });
    fireEvent.click(screen.getByRole('button', { name: '保存 Token' }));

    expect(await screen.findByText(`Token 长度不能超过 ${TOKEN_MAX_LENGTH} 个字符。`)).toBeTruthy();
    expect(tokenSave).not.toHaveBeenCalled();
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

  it('解密失败时允许覆盖保存或清除', async () => {
    const bridge = {
      tokenStatus: vi.fn(async () => ({
        ok: true as const,
        value: {
          configured: false,
          storage: 'decryptFailed' as const,
          message: '已保存的凭据无法解密。',
        },
      })),
      tokenSave: vi.fn(async () => ({
        ok: true as const,
        value: { configured: true, storage: 'available' as const, message: null },
      })),
      tokenClear: vi.fn(async () => ({
        ok: true as const,
        value: { configured: false, storage: 'available' as const, message: null },
      })),
    };

    render(<TokenSettingsPanel bridge={bridge} />);
    await waitFor(() => expect(screen.getByText(/无法解密/)).toBeTruthy());
    expect(screen.getByRole('button', { name: '保存 Token' })).toHaveProperty('disabled', false);
    expect(screen.getByRole('button', { name: '清除 Token' })).toHaveProperty('disabled', false);
  });

  it('清除失败显示清除文案', async () => {
    const bridge = {
      tokenStatus: vi.fn(async () => ({
        ok: true as const,
        value: { configured: true, storage: 'available' as const, message: null },
      })),
      tokenSave: vi.fn(),
      tokenClear: vi.fn(async () => ({
        ok: false as const,
        error: {
          kind: 'accessDenied' as const,
          code: 'tokenStorageUnavailable',
          messageKey: 'token.storageUnavailable',
          message: '系统安全存储不可用。',
        },
      })),
    };

    render(<TokenSettingsPanel bridge={bridge} />);
    await waitFor(() => expect(screen.getByText(/Token 已配置/)).toBeTruthy());
    fireEvent.click(screen.getByRole('button', { name: '清除 Token' }));
    await waitFor(() => expect(screen.getByText(/Token 清除失败/)).toBeTruthy());
  });
});
