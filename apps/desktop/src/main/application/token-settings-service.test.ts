import { describe, expect, it } from 'vitest';

import {
  InMemoryEncryptedBlobStore,
  SafeStorageTokenStore,
  type SafeStorageLike,
} from '../persistence/secret-store';
import { TokenSettingsService } from './token-settings-service';

function safeStorage(
  options: {
    readonly available?: boolean;
    readonly failDecrypt?: boolean;
    readonly backend?: string;
  } = {},
): SafeStorageLike {
  return {
    isEncryptionAvailable: () => options.available ?? true,
    encryptString: (value) => Buffer.from(`encrypted:${value}`),
    decryptString: (value) => {
      if (options.failDecrypt) {
        throw new Error('decrypt failed');
      }
      return value.toString().slice('encrypted:'.length);
    },
    getSelectedStorageBackend: () => options.backend ?? 'keychain',
  };
}

describe('TokenSettingsService', () => {
  it('返回配置状态，保存后不回显 token，清除后变为未配置', () => {
    const service = new TokenSettingsService(
      new SafeStorageTokenStore(safeStorage(), new InMemoryEncryptedBlobStore()),
    );

    expect(service.status()).toEqual({
      configured: false,
      storage: 'available',
      message: null,
    });
    expect(service.save('secret-token')).toEqual({
      configured: true,
      storage: 'available',
      message: null,
    });
    expect(JSON.stringify(service.status())).not.toContain('secret-token');
    expect(service.clear()).toEqual({
      configured: false,
      storage: 'available',
      message: null,
    });
  });

  it('安全存储不可用或解密失败时 fail-closed', () => {
    const unavailable = new TokenSettingsService(
      new SafeStorageTokenStore(
        safeStorage({ available: false }),
        new InMemoryEncryptedBlobStore(),
      ),
    );
    expect(unavailable.status()).toEqual({
      configured: false,
      storage: 'unavailable',
      message: '系统安全存储不可用。',
    });
    expect(() => unavailable.save('secret-token')).toThrow('系统安全存储不可用。');

    const blob = new InMemoryEncryptedBlobStore();
    const writer = new SafeStorageTokenStore(safeStorage(), blob);
    writer.saveToken('secret-token');
    const decryptFailed = new TokenSettingsService(
      new SafeStorageTokenStore(safeStorage({ failDecrypt: true }), blob),
    );
    expect(decryptFailed.status()).toEqual({
      configured: false,
      storage: 'decryptFailed',
      message: '已保存的凭据无法解密。',
    });
    expect(JSON.stringify(decryptFailed.status())).not.toContain('secret-token');
  });

  it('拒绝空 token', () => {
    const service = new TokenSettingsService(
      new SafeStorageTokenStore(safeStorage(), new InMemoryEncryptedBlobStore()),
    );
    expect(() => service.save('   ')).toThrow('Token 不能为空。');
  });
});
