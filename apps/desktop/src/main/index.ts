import { app, BrowserWindow, safeStorage } from 'electron';

import { bootstrapPersistence, type PersistenceBootstrapResult } from '@coc-helper/domain';

import { ImportCoordinator } from './application/import-coordinator';
import { createImportCoordinatorFromPersistence } from './application/persistence-boundary';
import { getCatalogService } from './catalog-service';
import { FileEncryptedBlobStore, SafeStorageTokenStore } from './persistence/secret-store';
import { installAppProtocolHandler, registerAppScheme } from './protocol';
import { isAllowedRendererUrl } from './security-policy';
import { createMainWindow, registerApplicationHandlers } from './windows';

declare const MAIN_WINDOW_WEBPACK_ENTRY: string;

registerAppScheme();
app.enableSandbox();
if (process.platform === 'linux' && process.env.CI === 'true') {
  // GitHub-hosted Linux 没有用户命名空间，Chromium sandbox 无法启动。
  // 仅 CI Linux 关闭 OS sandbox；macOS packaged app 保持 sandbox。
  app.commandLine.appendSwitch('no-sandbox');
}

const smokeMode = process.argv.includes('--smoke') || process.env.COCHELPER_SMOKE === '1';

/** E3-01-C 交给 #276 的持久化边界；smoke 也可复用。 */
let persistenceRuntime: PersistenceBootstrapResult | null = null;
let importCoordinator: ImportCoordinator | null = null;
let tokenStore: SafeStorageTokenStore | null = null;

export function getPersistenceRuntime(): PersistenceBootstrapResult | null {
  return persistenceRuntime;
}

export function getImportCoordinator(): ImportCoordinator | null {
  return importCoordinator;
}

export function getTokenStore(): SafeStorageTokenStore | null {
  return tokenStore;
}

function writeSmoke(message: string): void {
  process.stdout.write(`${message}\n`);
}

async function runSmoke(window: BrowserWindow): Promise<void> {
  const deadline = Date.now() + 20_000;
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error('smoke: 窗口加载超时'));
    }, 20_000);
    window.webContents.once('did-finish-load', () => {
      clearTimeout(timer);
      resolve();
    });
    window.webContents.once('did-fail-load', (_event, code, description) => {
      clearTimeout(timer);
      reject(new Error(`smoke: 加载失败 ${code} ${description}`));
    });
  });
  if (Date.now() > deadline) {
    throw new Error('smoke: 超时');
  }
  const url = window.webContents.getURL();
  if (!isAllowedRendererUrl(url, MAIN_WINDOW_WEBPACK_ENTRY)) {
    throw new Error(`smoke: 非法 renderer URL ${url}`);
  }
  const statusDeadline = Date.now() + 10_000;
  let status = '';
  while (Date.now() < statusDeadline) {
    status = (await window.webContents.executeJavaScript(
      `document.getElementById('status')?.textContent ?? ''`,
    )) as string;
    if (status === 'Electron 宿主已就绪') {
      break;
    }
    if (status === '宿主健康检查失败' || status === '宿主未就绪') {
      throw new Error(`smoke: ${status}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (status !== 'Electron 宿主已就绪') {
    throw new Error(`smoke: 宿主未就绪（status=${status}）`);
  }
  writeSmoke(`COCHELPER_SMOKE_OK ${url}`);
  app.exit(0);
}

const createWindow = (): void => {
  const window = createMainWindow();
  if (smokeMode) {
    void runSmoke(window).catch((error: unknown) => {
      writeSmoke(`COCHELPER_SMOKE_FAIL ${error instanceof Error ? error.message : String(error)}`);
      app.exit(1);
    });
  }
};

function initializePersistenceBoundary(): void {
  persistenceRuntime = bootstrapPersistence();
  importCoordinator = createImportCoordinatorFromPersistence(persistenceRuntime);
  tokenStore = new SafeStorageTokenStore(
    safeStorage,
    new FileEncryptedBlobStore(persistenceRuntime.paths.apiTokenEncrypted),
  );
}

app.whenReady().then(() => {
  try {
    initializePersistenceBoundary();
  } catch (error) {
    // 持久化启动失败不阻止窗口（便于诊断 UI）；边界状态保持 null。
    writeSmoke(
      `COCHELPER_PERSISTENCE_BOOT_FAIL ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  installAppProtocolHandler();
  getCatalogService().preload();
  registerApplicationHandlers();
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin' || smokeMode) {
    app.quit();
  }
});

app.on('web-contents-created', (_event, contents) => {
  contents.setWindowOpenHandler(() => ({ action: 'deny' }));
});
