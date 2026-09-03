import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';

import { assertFileSizeWithinLimit, atomicWriteFile } from '@coc-helper/domain';

export type CoAPITokenStoreError =
  | { readonly kind: 'unavailable'; readonly message: string }
  | { readonly kind: 'decryptFailed'; readonly message: string }
  | { readonly kind: 'encryptFailed'; readonly message: string }
  | { readonly kind: 'unexpected'; readonly message: string };

export type CoAPITokenStoring = {
  readToken(): string | null;
  saveToken(token: string): void;
  deleteToken(): void;
};

/** 密文字节持久化端口：与 safeStorage 加解密解耦，保证跨重启可读。 */
export type EncryptedBlobStore = {
  read(): Buffer | null;
  write(data: Buffer): void;
  delete(): void;
};

export type SafeStorageLike = {
  isEncryptionAvailable(): boolean;
  encryptString(plainText: string): Buffer;
  decryptString(encrypted: Buffer): string;
  /** Electron Linux：basic_text 表示明文密码硬编码，必须 fail-closed。 */
  getSelectedStorageBackend?(): string;
};

export type SafeStorageTokenStoreOptions = {
  readonly platform?: NodeJS.Platform;
};

/**
 * Electron safeStorage token store。
 * - 明文只经 safeStorage 进出；
 * - 密文经 EncryptedBlobStore 落盘，跨重启可恢复；
 * - 不可用 / Linux basic_text / 加解密失败一律 fail-closed，不明文 fallback；
 * - token 永不写入日志或错误 message。
 */
export class SafeStorageTokenStore implements CoAPITokenStoring {
  private readonly platform: NodeJS.Platform;

  constructor(
    private readonly safeStorage: SafeStorageLike,
    private readonly blobStore: EncryptedBlobStore,
    options: SafeStorageTokenStoreOptions = {},
  ) {
    this.platform = options.platform ?? process.platform;
  }

  readToken(): string | null {
    assertSafeStorageUsable(this.safeStorage, this.platform);
    const encrypted = this.blobStore.read();
    if (encrypted === null) {
      return null;
    }
    try {
      const plain = this.safeStorage.decryptString(encrypted);
      if (plain.length === 0) {
        return null;
      }
      return plain;
    } catch {
      throw {
        kind: 'decryptFailed',
        message: '凭据解密失败。',
      } satisfies CoAPITokenStoreError;
    }
  }

  saveToken(token: string): void {
    assertSafeStorageUsable(this.safeStorage, this.platform);
    let encrypted: Buffer;
    try {
      encrypted = this.safeStorage.encryptString(token);
    } catch {
      throw {
        kind: 'encryptFailed',
        message: '凭据加密失败。',
      } satisfies CoAPITokenStoreError;
    }
    this.blobStore.write(encrypted);
  }

  deleteToken(): void {
    this.blobStore.delete();
  }
}

export class FileEncryptedBlobStore implements EncryptedBlobStore {
  constructor(private readonly fileURL: string) {}

  read(): Buffer | null {
    if (!existsSync(this.fileURL)) {
      return null;
    }
    assertFileSizeWithinLimit(this.fileURL);
    return readFileSync(this.fileURL);
  }

  write(data: Buffer): void {
    mkdirSync(dirname(this.fileURL), { recursive: true });
    atomicWriteFile(this.fileURL, data);
  }

  delete(): void {
    if (existsSync(this.fileURL)) {
      rmSync(this.fileURL);
    }
  }
}

export class InMemoryEncryptedBlobStore implements EncryptedBlobStore {
  private bytes: Buffer | null = null;

  read(): Buffer | null {
    return this.bytes === null ? null : Buffer.from(this.bytes);
  }

  write(data: Buffer): void {
    this.bytes = Buffer.from(data);
  }

  delete(): void {
    this.bytes = null;
  }
}

export class InMemoryTokenStore implements CoAPITokenStoring {
  private token: string | null = null;

  readToken(): string | null {
    return this.token;
  }

  saveToken(token: string): void {
    this.token = token;
  }

  deleteToken(): void {
    this.token = null;
  }
}

export function assertSafeStorageUsable(
  safeStorage: SafeStorageLike,
  platform: NodeJS.Platform = process.platform,
): void {
  if (!safeStorage.isEncryptionAvailable()) {
    throw {
      kind: 'unavailable',
      message: '系统凭据加密不可用。',
    } satisfies CoAPITokenStoreError;
  }
  if (
    platform === 'linux' &&
    typeof safeStorage.getSelectedStorageBackend === 'function' &&
    safeStorage.getSelectedStorageBackend() === 'basic_text'
  ) {
    throw {
      kind: 'unavailable',
      message: '系统凭据加密后端不安全（basic_text）。',
    } satisfies CoAPITokenStoreError;
  }
}

export function isCoAPITokenStoreError(error: unknown): error is CoAPITokenStoreError {
  return (
    typeof error === 'object' &&
    error !== null &&
    'kind' in error &&
    typeof (error as CoAPITokenStoreError).kind === 'string'
  );
}

/** 确认诊断文本不含 token 明文。 */
export function assertTokenAbsentFromText(text: string, token: string): void {
  if (token.length > 0 && text.includes(token)) {
    throw new Error('诊断文本泄漏了 API token。');
  }
}
