import type { TokenStatusPayload, TokenStorageStatus } from '@coc-helper/contracts';

import { AppServiceError } from './app-authoritative-state';
import { isCoAPITokenStoreError, type CoAPITokenStoring } from '../persistence/secret-store';

const STORAGE_UNAVAILABLE_MESSAGE = '系统安全存储不可用。';
const DECRYPT_FAILED_MESSAGE = '已保存的凭据无法解密。';

export class TokenSettingsService {
  constructor(private readonly store: CoAPITokenStoring | null) {}

  status(): TokenStatusPayload {
    if (this.store === null) {
      return unavailableStatus(STORAGE_UNAVAILABLE_MESSAGE);
    }

    try {
      const token = this.store.readToken();
      return {
        configured: token !== null,
        storage: 'available',
        message: null,
      };
    } catch (error: unknown) {
      return statusFromStoreError(error);
    }
  }

  save(token: string): TokenStatusPayload {
    if (token.trim().length === 0) {
      throw new AppServiceError('validation', 'Token 不能为空。', 'token.empty');
    }
    if (this.store === null) {
      throw new AppServiceError(
        'unavailable',
        STORAGE_UNAVAILABLE_MESSAGE,
        'token.storageUnavailable',
      );
    }

    try {
      this.store.saveToken(token);
    } catch (error: unknown) {
      const status = statusFromStoreError(error);
      throw new AppServiceError(
        'unavailable',
        status.message ?? STORAGE_UNAVAILABLE_MESSAGE,
        status.storage === 'decryptFailed' ? 'token.decryptFailed' : 'token.storageUnavailable',
      );
    }
    return this.status();
  }

  clear(): TokenStatusPayload {
    if (this.store === null) {
      throw new AppServiceError(
        'unavailable',
        STORAGE_UNAVAILABLE_MESSAGE,
        'token.storageUnavailable',
      );
    }

    try {
      this.store.deleteToken();
    } catch {
      throw new AppServiceError(
        'unavailable',
        STORAGE_UNAVAILABLE_MESSAGE,
        'token.storageUnavailable',
      );
    }
    return this.status();
  }
}

function statusFromStoreError(error: unknown): TokenStatusPayload {
  if (isCoAPITokenStoreError(error) && error.kind === 'decryptFailed') {
    return unavailableStatus(DECRYPT_FAILED_MESSAGE, 'decryptFailed');
  }
  return unavailableStatus(STORAGE_UNAVAILABLE_MESSAGE);
}

function unavailableStatus(
  message: string,
  storage: TokenStorageStatus = 'unavailable',
): TokenStatusPayload {
  return {
    configured: false,
    storage,
    message,
  };
}
