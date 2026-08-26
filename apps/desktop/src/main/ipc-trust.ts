import { IpcValidationError } from './ipc-schema';
import { isAllowedRendererUrl } from './security-policy';

export type SenderTrustInput = {
  destroyed: boolean;
  frameUrl: string | undefined;
};

export function assertTrustedSenderState(input: SenderTrustInput, webpackEntry: string): void {
  if (input.destroyed) {
    throw new IpcValidationError('sender 已销毁', 'senderDestroyed', 'ipc.senderDestroyed');
  }
  if (input.frameUrl === undefined || !isAllowedRendererUrl(input.frameUrl, webpackEntry)) {
    throw new IpcValidationError('拒绝未授权 sender', 'untrustedSender', 'ipc.untrustedSender');
  }
}
