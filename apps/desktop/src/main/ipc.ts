import { ipcMain, type IpcMainInvokeEvent } from 'electron';

import { APP_HEALTH_CHANNEL } from '@coc-helper/contracts';

import { IpcValidationError, appHealthResponse, parseAppHealthRequest } from './ipc-schema';
import { isAllowedRendererUrl } from './security-policy';

export function assertTrustedSender(event: IpcMainInvokeEvent, webpackEntry: string): void {
  if (event.sender.isDestroyed()) {
    throw new IpcValidationError('sender 已销毁');
  }
  const frameUrl = event.senderFrame?.url;
  if (frameUrl === undefined || !isAllowedRendererUrl(frameUrl, webpackEntry)) {
    throw new IpcValidationError('拒绝未授权 sender');
  }
}

export function registerIpcHandlers(webpackEntry: string): void {
  ipcMain.handle(APP_HEALTH_CHANNEL, (event, payload: unknown) => {
    assertTrustedSender(event, webpackEntry);
    parseAppHealthRequest(payload);
    return appHealthResponse();
  });
}
