import {
  APP_HEALTH_CHANNEL,
  APP_SNAPSHOT_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  REQUEST_ID_MAX_LENGTH,
  STATE_CHANGED_CHANNEL,
  UPGRADE_OVERVIEW_CHANNEL,
  VILLAGE_DETAIL_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  emptyObjectRequestSchema,
  emptyProjectionRequestSchema,
  importCommitRequestSchema,
  importDiscardRequestSchema,
  importPrepareRequestSchema,
  isSafeIpcDiagnosticText,
  resultOk,
  villageDetailRequestSchema,
  villageSelectRequestSchema,
  type AppHealthResponse,
  type AppSnapshotRequest,
  type CancelRequest,
  type ImportCommitRequest,
  type ImportDiscardRequest,
  type ImportPrepareRequest,
  type IpcError,
  type RequestId,
  type UpgradeOverviewRequest,
  type VillageDetailRequest,
  type VillageSelectRequest,
} from '@coc-helper/contracts';
import { z } from 'zod';

import { redactDiagnosticText } from './redaction';

const cancelRequestSchema = z
  .object({
    requestId: z
      .string()
      .min(1)
      .max(REQUEST_ID_MAX_LENGTH)
      .regex(/^[\x21-\x7e]+$/),
  })
  .strict();

const appHealthRequestSchema = emptyObjectRequestSchema.optional();
const appSnapshotRequestSchema = emptyObjectRequestSchema.optional();

const IPC_VALIDATION_ERROR_DEFINITIONS = {
  invalidRequest: {
    code: 'invalidRequest',
    messageKey: 'ipc.invalidRequest',
  },
  invalidCancelRequest: {
    code: 'invalidCancelRequest',
    messageKey: 'ipc.invalidCancelRequest',
  },
  senderDestroyed: {
    code: 'senderDestroyed',
    messageKey: 'ipc.senderDestroyed',
  },
  untrustedSender: {
    code: 'untrustedSender',
    messageKey: 'ipc.untrustedSender',
  },
} as const;

type IpcValidationCode = keyof typeof IPC_VALIDATION_ERROR_DEFINITIONS;
type IpcValidationDefinition = (typeof IPC_VALIDATION_ERROR_DEFINITIONS)[IpcValidationCode];

export class IpcValidationError extends Error {
  override readonly name = 'IpcValidationError';
  readonly kind = 'validation' as const;
  readonly code: IpcValidationCode;
  readonly messageKey: string;

  constructor(message: string, code: IpcValidationCode = 'invalidRequest') {
    const definition = validationErrorDefinition(code);
    super(message);
    this.code = definition.code;
    this.messageKey = definition.messageKey;
  }
}

export function parseAppHealthRequest(payload: unknown): void {
  const result = appHealthRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('app.health 参数不合法');
  }
}

export function parseAppSnapshotRequest(payload: unknown): AppSnapshotRequest {
  const result = appSnapshotRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('app.snapshot 参数不合法');
  }
  return {};
}

export function parseVillageSelectRequest(payload: unknown): VillageSelectRequest {
  const result = villageSelectRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('village.select 参数不合法');
  }
  return result.data;
}

export function parseImportPrepareRequest(payload: unknown): ImportPrepareRequest {
  const result = importPrepareRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('import.prepare 参数不合法');
  }
  const villageId = result.data.villageId;
  return villageId === undefined
    ? { text: result.data.text }
    : { text: result.data.text, villageId };
}

export function parseImportCommitRequest(payload: unknown): ImportCommitRequest {
  const result = importCommitRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('import.commit 参数不合法');
  }
  return result.data;
}

export function parseImportDiscardRequest(payload: unknown): ImportDiscardRequest {
  const result = importDiscardRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('import.discard 参数不合法');
  }
  return result.data;
}

export function parseUpgradeOverviewRequest(payload: unknown): UpgradeOverviewRequest {
  const result = emptyProjectionRequestSchema.optional().safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('upgrade.overview 参数不合法');
  }
  return {};
}

export function parseVillageDetailRequest(payload: unknown): VillageDetailRequest {
  const result = villageDetailRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('village.detail 参数不合法');
  }
  return result.data;
}

export function parseCancelRequest(payload: unknown): CancelRequest {
  const result = cancelRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('取消请求参数不合法', 'invalidCancelRequest');
  }
  return { requestId: result.data.requestId as RequestId };
}

export function appHealthResponse(): AppHealthResponse {
  return resultOk({ app: 'coc-helper' });
}

/** 将内部异常收敛成不泄露原始上下文的 IPC 错误。 */
export function toIpcError(error: unknown): IpcError {
  if (error instanceof IpcValidationError) {
    const definition = validationErrorDefinition(error.code);
    const message = redactDiagnosticText(error.message);
    return {
      kind: 'validation',
      code: definition.code,
      messageKey: definition.messageKey,
      message: isSafeIpcDiagnosticText(message) ? message : '请求参数不合法',
    };
  }
  if (isAppServiceError(error)) {
    const message = redactDiagnosticText(error.message);
    return {
      kind: mapAppServiceKind(error.code),
      code: error.code,
      messageKey: `app.${error.code}`,
      message: isSafeIpcDiagnosticText(message) ? message : '应用服务错误。',
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

export const REGISTERED_IPC_CHANNELS = [
  APP_HEALTH_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  APP_SNAPSHOT_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  UPGRADE_OVERVIEW_CHANNEL,
  VILLAGE_DETAIL_CHANNEL,
  STATE_CHANGED_CHANNEL,
] as const;

function isAbortError(error: unknown): boolean {
  return (
    (error instanceof Error && error.name === 'AbortError') ||
    (typeof error === 'object' &&
      error !== null &&
      'name' in error &&
      (error as { name?: unknown }).name === 'AbortError')
  );
}

function isAppServiceError(
  error: unknown,
): error is Error & { code: 'notFound' | 'unavailable' | 'validation' | 'conflict' } {
  return (
    typeof error === 'object' &&
    error !== null &&
    (error as { name?: unknown }).name === 'AppServiceError' &&
    typeof (error as { code?: unknown }).code === 'string' &&
    typeof (error as { message?: unknown }).message === 'string'
  );
}

function mapAppServiceKind(
  code: 'notFound' | 'unavailable' | 'validation' | 'conflict',
): IpcError['kind'] {
  switch (code) {
    case 'notFound':
      return 'notFound';
    case 'unavailable':
      return 'accessDenied';
    case 'validation':
      return 'validation';
    case 'conflict':
      return 'validation';
  }
}

function validationErrorDefinition(code: string): IpcValidationDefinition {
  return Object.hasOwn(IPC_VALIDATION_ERROR_DEFINITIONS, code)
    ? IPC_VALIDATION_ERROR_DEFINITIONS[code as IpcValidationCode]
    : IPC_VALIDATION_ERROR_DEFINITIONS.invalidRequest;
}
