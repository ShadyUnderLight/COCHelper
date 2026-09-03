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

export type SafeStorageLike = {
  isEncryptionAvailable(): boolean;
  encryptString(plainText: string): Buffer;
  decryptString(encrypted: Buffer): string;
};

/**
 * Electron safeStorage token store。不可用/解密失败 fail-closed，不明文 fallback。
 * token 永不写入日志或错误 message 正文。
 */
export class SafeStorageTokenStore implements CoAPITokenStoring {
  private encrypted: Buffer | null = null;

  constructor(
    private readonly safeStorage: SafeStorageLike,
    private readonly initialEncrypted: Buffer | null = null,
  ) {
    this.encrypted = initialEncrypted;
  }

  /** 测试/进程内快照：仅返回密文字节，绝不返回明文。 */
  snapshotEncrypted(): Buffer | null {
    return this.encrypted === null ? null : Buffer.from(this.encrypted);
  }

  readToken(): string | null {
    if (!this.safeStorage.isEncryptionAvailable()) {
      throw {
        kind: 'unavailable',
        message: '系统凭据加密不可用。',
      } satisfies CoAPITokenStoreError;
    }
    if (this.encrypted === null) {
      return null;
    }
    try {
      const plain = this.safeStorage.decryptString(this.encrypted);
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
    if (!this.safeStorage.isEncryptionAvailable()) {
      throw {
        kind: 'unavailable',
        message: '系统凭据加密不可用。',
      } satisfies CoAPITokenStoreError;
    }
    try {
      this.encrypted = this.safeStorage.encryptString(token);
    } catch {
      throw {
        kind: 'encryptFailed',
        message: '凭据加密失败。',
      } satisfies CoAPITokenStoreError;
    }
  }

  deleteToken(): void {
    this.encrypted = null;
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
