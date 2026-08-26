import type { WebPreferences } from 'electron';

export const APP_PROTOCOL = 'cochelper';
export const APP_HOST = 'app';

export const SECURE_WEB_PREFERENCES: WebPreferences = {
  nodeIntegration: false,
  nodeIntegrationInWorker: false,
  nodeIntegrationInSubFrames: false,
  contextIsolation: true,
  sandbox: true,
  webSecurity: true,
  allowRunningInsecureContent: false,
  webviewTag: false,
  navigateOnDragDrop: false,
  enableBlinkFeatures: '',
};

export const PRODUCTION_CONTENT_SECURITY_POLICY = [
  "default-src 'none'",
  `script-src ${APP_PROTOCOL}:`,
  `style-src ${APP_PROTOCOL}: 'unsafe-inline'`,
  `img-src ${APP_PROTOCOL}: data:`,
  `font-src ${APP_PROTOCOL}:`,
  `connect-src ${APP_PROTOCOL}:`,
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
  "object-src 'none'",
].join('; ');

/** 开发态 webpack-dev-server 需要 eval 与 localhost websocket。生产不得使用本策略。 */
export const DEV_CONTENT_SECURITY_POLICY = [
  "default-src 'none'",
  "script-src 'self' 'unsafe-eval' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'self' ws://127.0.0.1:* ws://localhost:* http://127.0.0.1:* http://localhost:*",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
  "object-src 'none'",
].join('; ');

export function isLocalDevServerUrl(url: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'ws:') {
    return false;
  }
  if (parsed.hostname !== 'localhost' && parsed.hostname !== '127.0.0.1') {
    return false;
  }
  return parsed.port.length > 0;
}

export function isAppProtocolUrl(url: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  return parsed.protocol === `${APP_PROTOCOL}:` && parsed.hostname === APP_HOST;
}

export function isAllowedRendererUrl(url: string, webpackEntry: string): boolean {
  if (isAppProtocolUrl(url)) {
    return true;
  }
  if (!isLocalDevServerUrl(webpackEntry)) {
    return false;
  }
  return isLocalDevServerUrl(url) && originOf(url) === originOf(webpackEntry);
}

export function isAllowedExternalUrl(_url: string): boolean {
  return false;
}

export function resolveRendererLoadUrl(webpackEntry: string): string {
  if (isLocalDevServerUrl(webpackEntry)) {
    return webpackEntry;
  }
  return `${APP_PROTOCOL}://${APP_HOST}/index.html`;
}

export function contentSecurityPolicyFor(webpackEntry: string): string {
  return isLocalDevServerUrl(webpackEntry)
    ? DEV_CONTENT_SECURITY_POLICY
    : PRODUCTION_CONTENT_SECURITY_POLICY;
}

function originOf(url: string): string {
  const parsed = new URL(url);
  return `${parsed.protocol}//${parsed.host}`;
}
