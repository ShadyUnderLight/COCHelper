import {
  APP_HEALTH_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  isCancelRequest,
  isIpcError,
  isResult,
  type AppHealthResponse,
  type CancelRequest,
  type DesktopBridge,
} from '@coc-helper/contracts';

export function isAppHealthResponse(value: unknown): value is AppHealthResponse {
  return isResult(
    value,
    (payload): payload is { app: 'coc-helper' } =>
      isPlainObject(payload) && Object.keys(payload).length === 1 && payload.app === 'coc-helper',
    isIpcError,
  );
}

export function createDesktopBridge(
  invoke: (channel: typeof APP_HEALTH_CHANNEL, request?: Record<string, never>) => Promise<unknown>,
  send: (channel: typeof REQUEST_CANCEL_CHANNEL, request: CancelRequest) => void,
): DesktopBridge {
  return {
    health: async (request) => {
      const result = await invoke(APP_HEALTH_CHANNEL, request);
      if (!isAppHealthResponse(result)) {
        throw new Error('app.health 返回值不合法');
      }
      return result;
    },
    cancel: (request) => {
      if (!isCancelRequest(request)) {
        throw new Error('request.cancel 参数不合法');
      }
      send(REQUEST_CANCEL_CHANNEL, request);
    },
  };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype
  );
}
