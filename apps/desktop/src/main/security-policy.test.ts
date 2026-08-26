import { describe, expect, it } from 'vitest';

import {
  APP_HOST,
  APP_PROTOCOL,
  DEV_CONTENT_SECURITY_POLICY,
  PRODUCTION_CONTENT_SECURITY_POLICY,
  SECURE_WEB_PREFERENCES,
  contentSecurityPolicyFor,
  isAllowedExternalUrl,
  isAllowedRendererUrl,
  isAppProtocolUrl,
  isLocalDevServerUrl,
  resolveRendererLoadUrl,
} from './security-policy';

describe('SECURE_WEB_PREFERENCES', () => {
  it('默认关闭 Node 直通并开启隔离与沙箱', () => {
    expect(SECURE_WEB_PREFERENCES.nodeIntegration).toBe(false);
    expect(SECURE_WEB_PREFERENCES.nodeIntegrationInWorker).toBe(false);
    expect(SECURE_WEB_PREFERENCES.nodeIntegrationInSubFrames).toBe(false);
    expect(SECURE_WEB_PREFERENCES.contextIsolation).toBe(true);
    expect(SECURE_WEB_PREFERENCES.sandbox).toBe(true);
    expect(SECURE_WEB_PREFERENCES.webSecurity).toBe(true);
    expect(SECURE_WEB_PREFERENCES.allowRunningInsecureContent).toBe(false);
    expect(SECURE_WEB_PREFERENCES.webviewTag).toBe(false);
  });
});

describe('renderer URL allowlist', () => {
  it('只接受 cochelper://app 与锁定的 localhost 开发服', () => {
    expect(isAppProtocolUrl(`${APP_PROTOCOL}://${APP_HOST}/index.html`)).toBe(true);
    expect(isAppProtocolUrl('https://example.com/')).toBe(false);
    expect(isLocalDevServerUrl('http://localhost:9000/main_window')).toBe(true);
    expect(isLocalDevServerUrl('http://localhost/main_window')).toBe(false);
    expect(isLocalDevServerUrl('https://localhost:9000/main_window')).toBe(false);
    expect(isLocalDevServerUrl('http://evil.example/')).toBe(false);
  });

  it('开发态不允许跳到其他 origin', () => {
    const entry = 'http://localhost:9000/main_window';
    expect(isAllowedRendererUrl('http://localhost:9000/other', entry)).toBe(true);
    expect(isAllowedRendererUrl('http://127.0.0.1:9000/main_window', entry)).toBe(false);
    expect(isAllowedRendererUrl('http://localhost:9001/main_window', entry)).toBe(false);
    expect(isAllowedRendererUrl('https://example.com/', entry)).toBe(false);
  });

  it('生产态只允许自定义协议', () => {
    const entry = 'file:///tmp/index.html';
    expect(isAllowedRendererUrl(`${APP_PROTOCOL}://${APP_HOST}/index.html`, entry)).toBe(true);
    expect(isAllowedRendererUrl('http://localhost:9000/main_window', entry)).toBe(false);
    expect(isAllowedRendererUrl('file:///tmp/index.html', entry)).toBe(false);
  });

  it('openExternal 白名单为空', () => {
    expect(isAllowedExternalUrl('https://developer.clashofclans.com')).toBe(false);
    expect(isAllowedExternalUrl('https://example.com')).toBe(false);
  });

  it('按入口选择加载 URL 与 CSP', () => {
    expect(resolveRendererLoadUrl('http://localhost:9000/main_window')).toBe(
      'http://localhost:9000/main_window',
    );
    expect(resolveRendererLoadUrl('file:///tmp/index.html')).toBe(
      `${APP_PROTOCOL}://${APP_HOST}/index.html`,
    );
    expect(contentSecurityPolicyFor('http://localhost:9000/main_window')).toBe(
      DEV_CONTENT_SECURITY_POLICY,
    );
    expect(contentSecurityPolicyFor('file:///tmp/index.html')).toBe(
      PRODUCTION_CONTENT_SECURITY_POLICY,
    );
    expect(PRODUCTION_CONTENT_SECURITY_POLICY).toContain(`${APP_PROTOCOL}:`);
    expect(PRODUCTION_CONTENT_SECURITY_POLICY).not.toContain('unsafe-eval');
  });
});
