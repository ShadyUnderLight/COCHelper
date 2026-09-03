import { describe, expect, it } from 'vitest';

import { redactDiagnosticText } from '../redaction';
import {
  assertTokenAbsentFromText,
  InMemoryTokenStore,
  SafeStorageTokenStore,
  type SafeStorageLike,
} from './secret-store';

function fakeSafeStorage(options: {
  readonly available?: boolean;
  readonly failDecrypt?: boolean;
  readonly failEncrypt?: boolean;
}): SafeStorageLike {
  return {
    isEncryptionAvailable(): boolean {
      return options.available ?? true;
    },
    encryptString(plainText: string): Buffer {
      if (options.failEncrypt) {
        throw new Error('encrypt boom');
      }
      return Buffer.from(`enc:${plainText}`, 'utf8');
    },
    decryptString(encrypted: Buffer): string {
      if (options.failDecrypt) {
        throw new Error('decrypt boom');
      }
      const text = encrypted.toString('utf8');
      if (!text.startsWith('enc:')) {
        throw new Error('bad cipher');
      }
      return text.slice(4);
    },
  };
}

describe('SafeStorageTokenStore', () => {
  it('save/read/delete 往返且密文快照不含明文', () => {
    const store = new SafeStorageTokenStore(fakeSafeStorage({}));
    const token = 'super-secret-token-value';
    store.saveToken(token);
    expect(store.readToken()).toBe(token);
    const encrypted = store.snapshotEncrypted();
    expect(encrypted).not.toBeNull();
    expect(encrypted!.toString('utf8')).not.toBe(token);
    store.deleteToken();
    expect(store.readToken()).toBeNull();
  });

  it('加密不可用时 fail-closed', () => {
    const store = new SafeStorageTokenStore(fakeSafeStorage({ available: false }));
    expect(() => store.saveToken('x')).toThrow();
    expect(() => store.readToken()).toThrow();
  });

  it('解密失败 fail-closed 且错误不含 token', () => {
    const token = 'leak-me-not';
    const store = new SafeStorageTokenStore(fakeSafeStorage({ failDecrypt: true }));
    store.saveToken(token);
    try {
      store.readToken();
      expect.unreachable('expected decrypt failure');
    } catch (error) {
      const message = error instanceof Error ? error.message : JSON.stringify(error);
      assertTokenAbsentFromText(message, token);
      expect(message).not.toContain(token);
    }
  });

  it('redaction 与 token 断言配合', () => {
    const token = 'Bearer-secret-xyz';
    const redacted = redactDiagnosticText(`Authorization: Bearer ${token}`);
    assertTokenAbsentFromText(redacted, token);
  });
});

describe('InMemoryTokenStore', () => {
  it('支持测试替身', () => {
    const store = new InMemoryTokenStore();
    store.saveToken('t');
    expect(store.readToken()).toBe('t');
    store.deleteToken();
    expect(store.readToken()).toBeNull();
  });
});
