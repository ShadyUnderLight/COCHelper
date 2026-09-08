import { BrowserWindow, app, ipcMain, type IpcMainEvent, type IpcMainInvokeEvent } from 'electron';

import {
  API_REFRESH_CHANNEL,
  APP_HEALTH_CHANNEL,
  APP_SNAPSHOT_CHANNEL,
  CAPITAL_RAID_LOAD_MORE_CHANNEL,
  CAPITAL_RAID_STATE_CHANNEL,
  CLAN_STATE_CHANNEL,
  CLAN_WAR_STATE_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  MANUAL_ADJUST_CHANNEL,
  MANUAL_CANCEL_CHANNEL,
  MANUAL_RECONCILE_CHANNEL,
  MANUAL_SETTLE_CHANNEL,
  MANUAL_START_CHANNEL,
  MANUAL_STATE_CHANNEL,
  OPERATION_PROGRESS_CHANNEL,
  PLAYER_STATE_CHANNEL,
  RECOVERY_EXPORT_CHANNEL,
  RECOVERY_RECOVER_JOURNAL_CHANNEL,
  RECOVERY_RESET_CHANNEL,
  RECOVERY_RESTORE_CHANNEL,
  RECOVERY_RESTORE_SAVED_CHANNEL,
  RECOVERY_STATUS_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  STATE_CHANGED_CHANNEL,
  UPGRADE_OVERVIEW_CHANNEL,
  VILLAGE_DETAIL_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  WAR_LOG_LOAD_MORE_CHANNEL,
  WAR_LOG_STATE_CHANNEL,
  resultErr,
  resultOk,
  type OperationProgressPayload,
  type StateChangedPayload,
} from '@coc-helper/contracts';

import { AppServiceError } from './application/app-authoritative-state';
import type { ApplicationServices } from './application/application-services';
import {
  appHealthResponse,
  parseApiRefreshRequest,
  parseAppHealthRequest,
  parseAppSnapshotRequest,
  parseCancelRequest,
  parseCapitalRaidLoadMoreRequest,
  parseCapitalRaidStateRequest,
  parseClanStateRequest,
  parseClanWarStateRequest,
  parseImportCommitRequest,
  parseImportDiscardRequest,
  parseImportPrepareRequest,
  parseManualAdjustRequest,
  parseManualCancelRequest,
  parseManualReconcileRequest,
  parseManualSettleRequest,
  parseManualStartRequest,
  parseManualStateRequest,
  parsePlayerStateRequest,
  parseRecoveryExportRequest,
  parseRecoveryRecoverJournalRequest,
  parseRecoveryResetRequest,
  parseRecoveryRestoreRequest,
  parseRecoveryRestoreSavedRequest,
  parseRecoveryStatusRequest,
  parseUpgradeOverviewRequest,
  parseVillageDetailRequest,
  parseVillageSelectRequest,
  parseWarLogLoadMoreRequest,
  parseWarLogStateRequest,
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

function requireOfficial(services: ApplicationServices) {
  if (services.official === null) {
    throw new AppServiceError('unavailable', '官方 API 服务尚未就绪。');
  }
  return services.official;
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
      return resultOk(
        requireServices(services).imports.commit(
          request.expectedGeneration,
          request.reconciliationDecision ?? 'applyNonConflicting',
        ),
      );
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

  ipcMain.handle(MANUAL_STATE_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseManualStateRequest(payload);
      const manual = requireServices(services).manual;
      if (manual === null) {
        throw new AppServiceError('unavailable', '手动升级服务尚未就绪。');
      }
      return resultOk(manual.getState(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(MANUAL_START_CHANNEL, async (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseManualStartRequest(payload);
      const manual = requireServices(services).manual;
      if (manual === null) {
        throw new AppServiceError('unavailable', '手动升级服务尚未就绪。');
      }
      return resultOk(await manual.start(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(MANUAL_CANCEL_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseManualCancelRequest(payload);
      const manual = requireServices(services).manual;
      if (manual === null) {
        throw new AppServiceError('unavailable', '手动升级服务尚未就绪。');
      }
      return resultOk(manual.cancel(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(MANUAL_ADJUST_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseManualAdjustRequest(payload);
      const manual = requireServices(services).manual;
      if (manual === null) {
        throw new AppServiceError('unavailable', '手动升级服务尚未就绪。');
      }
      return resultOk(manual.adjust(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(MANUAL_SETTLE_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseManualSettleRequest(payload);
      const manual = requireServices(services).manual;
      if (manual === null) {
        throw new AppServiceError('unavailable', '手动升级服务尚未就绪。');
      }
      return resultOk(manual.settle(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(MANUAL_RECONCILE_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseManualReconcileRequest(payload);
      const manual = requireServices(services).manual;
      if (manual === null) {
        throw new AppServiceError('unavailable', '手动升级服务尚未就绪。');
      }
      return resultOk(
        manual.reconcile({
          expectedGeneration: request.expectedGeneration,
          villageId: request.villageId,
          decision: request.decision,
        }),
      );
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(PLAYER_STATE_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parsePlayerStateRequest(payload);
      return resultOk(requireOfficial(requireServices(services)).playerState(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(CLAN_STATE_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseClanStateRequest(payload);
      return resultOk(requireOfficial(requireServices(services)).clanState(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(CLAN_WAR_STATE_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseClanWarStateRequest(payload);
      return resultOk(requireOfficial(requireServices(services)).clanWarState(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(WAR_LOG_STATE_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseWarLogStateRequest(payload);
      return resultOk(requireOfficial(requireServices(services)).warLogState(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(CAPITAL_RAID_STATE_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseCapitalRaidStateRequest(payload);
      return resultOk(requireOfficial(requireServices(services)).capitalRaidState(request));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(API_REFRESH_CHANNEL, async (event, payload: unknown) => {
    const senderId = event.sender.id;
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseApiRefreshRequest(payload);
      const signal = cancellation.start(senderId, request.requestId);
      try {
        return resultOk(await requireOfficial(requireServices(services)).refresh(request, signal));
      } finally {
        cancellation.finish(senderId, request.requestId);
      }
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(WAR_LOG_LOAD_MORE_CHANNEL, async (event, payload: unknown) => {
    const senderId = event.sender.id;
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseWarLogLoadMoreRequest(payload);
      const signal = cancellation.start(senderId, request.requestId);
      try {
        return resultOk(
          await requireOfficial(requireServices(services)).loadMoreWarLog(request, signal),
        );
      } finally {
        cancellation.finish(senderId, request.requestId);
      }
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(CAPITAL_RAID_LOAD_MORE_CHANNEL, async (event, payload: unknown) => {
    const senderId = event.sender.id;
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseCapitalRaidLoadMoreRequest(payload);
      const signal = cancellation.start(senderId, request.requestId);
      try {
        return resultOk(
          await requireOfficial(requireServices(services)).loadMoreCapitalRaid(request, signal),
        );
      } finally {
        cancellation.finish(senderId, request.requestId);
      }
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(RECOVERY_STATUS_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      parseRecoveryStatusRequest(payload);
      return resultOk(requireServices(services).recovery.status());
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(RECOVERY_EXPORT_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      parseRecoveryExportRequest(payload);
      return resultOk(requireServices(services).recovery.exportRaw());
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(RECOVERY_RESTORE_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseRecoveryRestoreRequest(payload);
      return resultOk(
        requireServices(services).recovery.restore(request.expectedGeneration, request.dataBase64),
      );
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(RECOVERY_RESTORE_SAVED_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseRecoveryRestoreSavedRequest(payload);
      return resultOk(
        requireServices(services).recovery.restoreFromSavedCopy(request.expectedGeneration),
      );
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(RECOVERY_RESET_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseRecoveryResetRequest(payload);
      return resultOk(requireServices(services).recovery.reset(request.expectedGeneration));
    } catch (error: unknown) {
      return resultErr(toIpcError(error));
    }
  });

  ipcMain.handle(RECOVERY_RECOVER_JOURNAL_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      const request = parseRecoveryRecoverJournalRequest(payload);
      return resultOk(
        requireServices(services).recovery.recoverJournal(request.expectedGeneration),
      );
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
    if (services.official !== null) {
      services.official.subscribeProgress((payload: OperationProgressPayload) => {
        broadcastOperationProgress(payload);
      });
    }
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

function broadcastOperationProgress(payload: OperationProgressPayload): void {
  for (const window of BrowserWindow.getAllWindows()) {
    if (!window.isDestroyed() && !window.webContents.isDestroyed()) {
      window.webContents.send(OPERATION_PROGRESS_CHANNEL, payload);
    }
  }
}
