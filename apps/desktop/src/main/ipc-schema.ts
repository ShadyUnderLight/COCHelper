import { z } from 'zod';

import {
  APP_HEALTH_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  REQUEST_ID_MAX_LENGTH,
  resultOk,
  type AppHealthResponse,
  type CancelRequest,
  type IpcError,
  type RequestId,
} from '@coc-helper/contracts';

import { redactDiagnosticText } from './redaction';

const appHealthRequestSchema = z.object({}).strict().optional();
const cancelRequestSchema = z
  .object({
    requestId: z
      .string()
      .min(1)
      .max(REQUEST_ID_MAX_LENGTH)
      .regex(/^[\x21-\x7e]+$/),
  })
  .strict();

export class IpcValidationError extends Error {
  override readonly name = 'IpcValidationError';
  readonly kind = 'validation' as const;
  readonly code: string;
  readonly messageKey: string;

  constructor(message: string, code = 'invalidRequest', messageKey = 'ipc.invalidRequest') {
    super(message);
    this.code = code;
    this.messageKey = messageKey;
  }
}

export function parseAppHealthRequest(payload: unknown): void {
  const result = appHealthRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('app.health 参数不合法');
  }
}

export function parseCancelRequest(payload: unknown): CancelRequest {
  const result = cancelRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError(
      '取消请求参数不合法',
      'invalidCancelRequest',
      'ipc.invalidCancelRequest',
    );
  }
  return { requestId: result.data.requestId as RequestId };
}

export function appHealthResponse(): AppHealthResponse {
  return resultOk({ app: 'coc-helper' });
}

/** 将内部异常收敛成不泄露原始上下文的 IPC 错误。 */
export function toIpcError(error: unknown): IpcError {
  if (error instanceof IpcValidationError) {
    return {
      kind: error.kind,
      code: error.code,
      messageKey: error.messageKey,
      message: redactDiagnosticText(error.message),
    };
  }
  if (isAbortError(error)) {
    return {
      kind: 'cancelled',
      code: 'requestCancelled',
      messageKey: 'ipc.requestCancelled',
      message: '请求已取消。',
    };
  }
  return {
    kind: 'internal',
    code: 'internalError',
    messageKey: 'ipc.internalError',
    message: '宿主内部错误。',
  };
}

export const REGISTERED_IPC_CHANNELS = [APP_HEALTH_CHANNEL, REQUEST_CANCEL_CHANNEL] as const;

function isAbortError(error: unknown): boolean {
  return (
    (error instanceof Error && error.name === 'AbortError') ||
    (typeof error === 'object' &&
      error !== null &&
      'name' in error &&
      (error as { name?: unknown }).name === 'AbortError')
  );
}
