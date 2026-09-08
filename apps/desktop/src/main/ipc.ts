import { BrowserWindow, app, ipcMain, type IpcMainEvent, type IpcMainInvokeEvent } from 'electron';

import {
  APP_HEALTH_CHANNEL,
  APP_SNAPSHOT_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  STATE_CHANGED_CHANNEL,
  UPGRADE_OVERVIEW_CHANNEL,
  VILLAGE_DETAIL_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  resultErr,
  resultOk,
  type StateChangedPayload,
} from '@coc-helper/contracts';

import { AppServiceError } from './application/app-authoritative-state';
import type { ApplicationServices } from './application/application-services';
import {
  appHealthResponse,
  parseAppHealthRequest,
  parseAppSnapshotRequest,
  parseCancelRequest,
  parseImportCommitRequest,
  parseImportDiscardRequest,
  parseImportPrepareRequest,
  parseUpgradeOverviewRequest,
  parseVillageDetailRequest,
  parseVillageSelectRequest,
  toIpcError,
} from './ipc-schema';
import { assertTrustedSenderState } from './ipc-trust';
import { RequestCancellationRegistry } from './request-cancellation';

type IpcSenderEvent = Pick<IpcMainInvokeEvent | IpcMainEvent, 'sender' | 'senderFrame'>;

function requireServices(services: ApplicationServices | null): ApplicationServices {
  if (services === null) {
    throw new AppServiceError('unavailable', '应用服务未就绪。');
  }
  return services;
}
export function assertTrustedSender(event: IpcSenderEvent, webpackEntry: string): void {
  assertTrustedSenderState(
    {
      destroyed: event.sender.isDestroyed(),
      frameUrl: event.senderFrame?.url,
    },
    webpackEntry,
  );
}

export function registerIpcHandlers(
  webpackEntry: string,
  options: {
    readonly cancellation?: RequestCancellationRegistry;
    readonly services?: ApplicationServices | null;
  } = {},
): RequestCancellationRegistry {
  const cancellation = options.cancellation ?? new RequestCancellationRegistry();
  const services = options.services ?? null;

  ipcMain.handle(APP_HEALTH_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      parseAppHealthRequest(payload);
      return appHealthResponse();
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(APP_SNAPSHOT_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      parseAppSnapshotRequest(payload);
      return resultOk(requireServices(services).lifecycle.snapshot());
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(VILLAGE_SELECT_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseVillageSelectRequest(payload);
      return resultOk(requireServices(services).villages.selectVillage(request.villageId));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(IMPORT_PREPARE_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseImportPrepareRequest(payload);
      return resultOk(requireServices(services).imports.prepare(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(IMPORT_COMMIT_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseImportCommitRequest(payload);
      return resultOk(requireServices(services).imports.commit(request.expectedGeneration));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(IMPORT_DISCARD_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseImportDiscardRequest(payload);
      return resultOk(requireServices(services).imports.discard(request.expectedGeneration));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(UPGRADE_OVERVIEW_CHANNEL, async (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      parseUpgradeOverviewRequest(payload);
      return resultOk(await requireServices(services).projections.upgradeOverview());
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(VILLAGE_DETAIL_CHANNEL, async (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseVillageDetailRequest(payload);
      return resultOk(await requireServices(services).projections.villageDetail(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.on(REQUEST_CANCEL_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseCancelRequest(payload);
      cancellation.cancel(event.sender.id, request.requestId);
    } catch {
      // send() 没有响应通道；拒绝请求或未知 requestId 都是安全 no-op。
    }
  });

  if (services !== null) {
    services.state.subscribe((payload: StateChangedPayload) => {
      broadcastStateChanged(payload);
    });
  }

  app.on('web-contents-created', (_event, contents) => {
    contents.once('destroyed', () => {
      cancellation.clearSender(contents.id);
    });
  });

  return cancellation;
}

function broadcastStateChanged(payload: StateChangedPayload): void {
  for (const window of BrowserWindow.getAllWindows()) {
    if (!window.isDestroyed() && !window.webContents.isDestroyed()) {
      window.webContents.send(STATE_CHANGED_CHANNEL, payload);
    }
  }
}
