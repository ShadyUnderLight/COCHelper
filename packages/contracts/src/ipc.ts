/** IPC 通道名。preload 只允许调用这里列出的通道。 */
export const APP_HEALTH_CHANNEL = 'app.health' as const;

export type AppHealthRequest = Record<string, never>;

export type AppHealthResponse = {
  ok: true;
  app: 'coc-helper';
};

/** renderer 经 contextBridge 可见的 API。不得包含 ipcRenderer。 */
export type DesktopBridge = {
  health: (request?: AppHealthRequest) => Promise<AppHealthResponse>;
};

export const DESKTOP_BRIDGE_KEYS = ['health'] as const satisfies ReadonlyArray<keyof DesktopBridge>;
