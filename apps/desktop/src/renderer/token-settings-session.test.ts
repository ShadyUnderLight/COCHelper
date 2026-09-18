import { describe, expect, it } from 'vitest';

import {
  applyTokenSaveFailure,
  applyTokenStatus,
  beginTokenSave,
  INITIAL_TOKEN_SETTINGS_STATE,
} from './token-settings-session';

const available = {
  configured: false,
  storage: 'available' as const,
  message: null,
};

describe('token-settings-session', () => {
  it('区分未配置、保存中、已配置', () => {
    const unconfigured = applyTokenStatus(available);
    expect(unconfigured.status).toBe('unconfigured');
    expect(beginTokenSave(unconfigured).status).toBe('saving');
    expect(applyTokenStatus({ configured: true, storage: 'available', message: null }).status).toBe(
      'configured',
    );
  });

  it('安全存储不可用时不当作普通错误', () => {
    const state = applyTokenStatus({
      configured: false,
      storage: 'unavailable',
      message: '系统安全存储不可用。',
    });
    expect(state.status).toBe('unavailable');
    expect(state.error).toBe('系统安全存储不可用。');
  });

  it('保存失败保留之前状态并展示错误', () => {
    const state = applyTokenSaveFailure(
      beginTokenSave(applyTokenStatus({ ...available, configured: true })),
      '保存失败',
    );
    expect(state.status).toBe('saveFailed');
    expect(state.token?.configured).toBe(true);
    expect(state.error).toBe('保存失败');
    expect(INITIAL_TOKEN_SETTINGS_STATE.status).toBe('loading');
  });
});
