import { app, ipcMain, type IpcMainEvent, type IpcMainInvokeEvent } from 'electron';

import { APP_HEALTH_CHANNEL, REQUEST_CANCEL_CHANNEL, resultErr } from '@coc-helper/contracts';

import {
  appHealthResponse,
  parseAppHealthRequest,
  parseCancelRequest,
  toIpcError,
} from './ipc-schema';
import { assertTrustedSenderState } from './ipc-trust';
import { RequestCancellationRegistry } from './request-cancellation';

type IpcSenderEvent = Pick<IpcMainInvokeEvent | IpcMainEvent, 'sender' | 'senderFrame'>;

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
  cancellation = new RequestCancellationRegistry(),
): RequestCancellationRegistry {
  ipcMain.handle(APP_HEALTH_CHANNEL, (event, payload: unknown) => {
    try {
      assertTrustedSender(event, webpackEntry);
      parseAppHealthRequest(payload);
      return appHealthResponse();
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

  app.on('web-contents-created', (_event, contents) => {
    contents.once('destroyed', () => {
      cancellation.clearSender(contents.id);
    });
  });

  return cancellation;
}
