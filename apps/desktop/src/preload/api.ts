import {
  APP_HEALTH_CHANNEL,
  type AppHealthResponse,
  type DesktopBridge,
} from '@coc-helper/contracts';

export function isAppHealthResponse(value: unknown): value is AppHealthResponse {
  return (
    typeof value === 'object' &&
    value !== null &&
    (value as { ok?: unknown }).ok === true &&
    (value as { app?: unknown }).app === 'coc-helper'
  );
}

export function createDesktopBridge(
  invoke: (channel: typeof APP_HEALTH_CHANNEL, request?: Record<string, never>) => Promise<unknown>,
): DesktopBridge {
  return {
    health: async (request) => {
      const result = await invoke(APP_HEALTH_CHANNEL, request);
      if (!isAppHealthResponse(result)) {
        throw new Error('app.health 返回值不合法');
      }
      return result;
    },
  };
}
