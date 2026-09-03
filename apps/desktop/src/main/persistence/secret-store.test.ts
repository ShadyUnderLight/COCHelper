import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { redactDiagnosticText } from '../redaction';
import {
  assertTokenAbsentFromText,
  FileEncryptedBlobStore,
  InMemoryEncryptedBlobStore,
  InMemoryTokenStore,
  SafeStorageTokenStore,
  type SafeStorageLike,
} from './secret-store';

function fakeSafeStorage(options: {
  readonly available?: boolean;
  readonly failDecrypt?: boolean;
  readonly failEncrypt?: boolean;
  readonly backend?: string;
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
    getSelectedStorageBackend(): string {
      return options.backend ?? 'keychain';
    },
  };
}

describe('SafeStorageTokenStore', () => {
  it('save/read/delete 往返且文件密文不含明文', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-token-'));
    const blob = new FileEncryptedBlobStore(join(directory, 'api-token.enc'));
    const store = new SafeStorageTokenStore(fakeSafeStorage({}), blob);
    const token = 'super-secret-token-value';
    store.saveToken(token);
    expect(store.readToken()).toBe(token);
    const encrypted = blob.read();
    expect(encrypted).not.toBeNull();
    expect(encrypted!.toString('utf8')).not.toBe(token);
    store.deleteToken();
    expect(store.readToken()).toBeNull();
    rmSync(directory, { recursive: true, force: true });
  });

  it('跨实例重启后仍可读 token', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-token-restart-'));
    const path = join(directory, 'api-token.enc');
    const token = 'durable-secret-token';
    const first = new SafeStorageTokenStore(fakeSafeStorage({}), new FileEncryptedBlobStore(path));
    first.saveToken(token);

    const second = new SafeStorageTokenStore(fakeSafeStorage({}), new FileEncryptedBlobStore(path));
    expect(second.readToken()).toBe(token);
    rmSync(directory, { recursive: true, force: true });
  });

  it('加密不可用时 fail-closed', () => {
    const store = new SafeStorageTokenStore(
      fakeSafeStorage({ available: false }),
      new InMemoryEncryptedBlobStore(),
    );
    expect(() => store.saveToken('x')).toThrow();
    expect(() => store.readToken()).toThrow();
  });

  it('Linux basic_text 后端 fail-closed', () => {
    const store = new SafeStorageTokenStore(
      fakeSafeStorage({ backend: 'basic_text' }),
      new InMemoryEncryptedBlobStore(),
      { platform: 'linux' },
    );
    expect(() => store.saveToken('x')).toThrow();
  });

  it('解密失败 fail-closed 且错误不含 token', () => {
    const token = 'leak-me-not';
    const store = new SafeStorageTokenStore(
      fakeSafeStorage({ failDecrypt: true }),
      new InMemoryEncryptedBlobStore(),
    );
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
    const token = 'opaque-secret-xyz';
    const message = ['Authorization', ': ', 'Bearer', ' ', token].join('');
    const redacted = redactDiagnosticText(message);
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
