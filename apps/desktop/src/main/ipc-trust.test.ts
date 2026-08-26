import { describe, expect, it } from 'vitest';

import { IpcValidationError } from './ipc-schema';
import { assertTrustedSenderState } from './ipc-trust';

describe('assertTrustedSenderState', () => {
  const productionEntry = 'file:///tmp/.webpack/renderer/main_window/index.html';
  const devEntry = 'http://localhost:9000/main_window';

  it('拒绝已销毁的 sender', () => {
    expect(() =>
      assertTrustedSenderState(
        { destroyed: true, frameUrl: 'cochelper://app/index.html' },
        productionEntry,
      ),
    ).toThrow(IpcValidationError);
  });

  it('拒绝远程 URL', () => {
    expect(() =>
      assertTrustedSenderState(
        { destroyed: false, frameUrl: 'https://evil.example/' },
        productionEntry,
      ),
    ).toThrow('拒绝未授权 sender');
  });

  it('拒绝错误的 localhost origin', () => {
    expect(() =>
      assertTrustedSenderState(
        { destroyed: false, frameUrl: 'http://localhost:9001/main_window' },
        devEntry,
      ),
    ).toThrow('拒绝未授权 sender');
  });

  it('拒绝缺失 frame URL', () => {
    expect(() =>
      assertTrustedSenderState({ destroyed: false, frameUrl: undefined }, productionEntry),
    ).toThrow('拒绝未授权 sender');
  });

  it('接受合法 cochelper://app', () => {
    expect(() =>
      assertTrustedSenderState(
        { destroyed: false, frameUrl: 'cochelper://app/index.html' },
        productionEntry,
      ),
    ).not.toThrow();
  });

  it('开发态只接受锁定的 webpack-dev-server origin', () => {
    expect(() =>
      assertTrustedSenderState(
        { destroyed: false, frameUrl: 'http://localhost:9000/main_window' },
        devEntry,
      ),
    ).not.toThrow();
  });
});
