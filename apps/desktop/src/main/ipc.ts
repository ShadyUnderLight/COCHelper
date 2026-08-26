import { ipcMain, type IpcMainInvokeEvent } from 'electron';

import { APP_HEALTH_CHANNEL } from '@coc-helper/contracts';

import { appHealthResponse, parseAppHealthRequest } from './ipc-schema';
import { assertTrustedSenderState } from './ipc-trust';

export function assertTrustedSender(event: IpcMainInvokeEvent, webpackEntry: string): void {
  assertTrustedSenderState(
    {
      destroyed: event.sender.isDestroyed(),
      frameUrl: event.senderFrame?.url,
    },
    webpackEntry,
  );
}

export function registerIpcHandlers(webpackEntry: string): void {
  ipcMain.handle(APP_HEALTH_CHANNEL, (event, payload: unknown) => {
    assertTrustedSender(event, webpackEntry);
    parseAppHealthRequest(payload);
    return appHealthResponse();
  });
}
