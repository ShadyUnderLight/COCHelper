import { BrowserWindow, session, shell } from 'electron';

import { registerIpcHandlers } from './ipc';
import {
  SECURE_WEB_PREFERENCES,
  contentSecurityPolicyFor,
  isAllowedExternalUrl,
  isAllowedRendererUrl,
  resolveRendererLoadUrl,
} from './security-policy';

declare const MAIN_WINDOW_PRELOAD_WEBPACK_ENTRY: string;
declare const MAIN_WINDOW_WEBPACK_ENTRY: string;

export function applySessionGuards(webpackEntry: string): void {
  const ses = session.defaultSession;
  ses.setPermissionRequestHandler((_webContents, _permission, callback) => {
    callback(false);
  });
  ses.setPermissionCheckHandler(() => false);
  ses.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [contentSecurityPolicyFor(webpackEntry)],
      },
    });
  });
}

export function attachWindowGuards(window: BrowserWindow, webpackEntry: string): void {
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event, url) => {
    if (!isAllowedRendererUrl(url, webpackEntry)) {
      event.preventDefault();
    }
  });
  window.webContents.on('will-redirect', (event, url) => {
    if (!isAllowedRendererUrl(url, webpackEntry)) {
      event.preventDefault();
    }
  });
  window.webContents.on('will-attach-webview', (event) => {
    event.preventDefault();
  });
}

export function createMainWindow(): BrowserWindow {
  const webpackEntry = MAIN_WINDOW_WEBPACK_ENTRY;
  const window = new BrowserWindow({
    width: 1100,
    height: 760,
    show: !process.argv.includes('--smoke'),
    webPreferences: {
      ...SECURE_WEB_PREFERENCES,
      preload: MAIN_WINDOW_PRELOAD_WEBPACK_ENTRY,
    },
  });
  attachWindowGuards(window, webpackEntry);
  void window.loadURL(resolveRendererLoadUrl(webpackEntry));
  return window;
}

export function registerApplicationHandlers(): void {
  registerIpcHandlers(MAIN_WINDOW_WEBPACK_ENTRY);
  applySessionGuards(MAIN_WINDOW_WEBPACK_ENTRY);
}

export function openExternalIfAllowed(url: string): Promise<void> {
  if (!isAllowedExternalUrl(url)) {
    return Promise.reject(new Error('openExternal 未在白名单中'));
  }
  return shell.openExternal(url);
}
