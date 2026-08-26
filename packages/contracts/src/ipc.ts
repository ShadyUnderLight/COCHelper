import type { Result } from './result';

/** IPC 通道名。preload 只允许调用这里列出的通道。 */
export const APP_HEALTH_CHANNEL = 'app.health' as const;
export const REQUEST_CANCEL_CHANNEL = 'request.cancel' as const;

export const REQUEST_ID_MAX_LENGTH = 128;

export type RequestId = string & { readonly __brand: 'RequestId' };

export type AppHealthRequest = Record<string, never>;

export type AppHealthPayload = {
  readonly app: 'coc-helper';
};

export type AppHealthResponse = Result<AppHealthPayload>;

export type CancelRequest = {
  readonly requestId: RequestId;
};

export function isRequestId(value: unknown): value is RequestId {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= REQUEST_ID_MAX_LENGTH &&
    /^[\x21-\x7e]+$/.test(value)
  );
}

export function isCancelRequest(value: unknown): value is CancelRequest {
  if (
    typeof value !== 'object' ||
    value === null ||
    Object.getPrototypeOf(value) !== Object.prototype
  ) {
    return false;
  }
  const record = value as Record<string, unknown>;
  return Object.keys(record).length === 1 && isRequestId(record.requestId);
}

/** renderer 经 contextBridge 可见的 API。不得包含 ipcRenderer。 */
export type DesktopBridge = {
  health: (request?: AppHealthRequest) => Promise<AppHealthResponse>;
  cancel: (request: CancelRequest) => void;
};

export const DESKTOP_BRIDGE_KEYS = ['health', 'cancel'] as const satisfies ReadonlyArray<
  keyof DesktopBridge
>;
