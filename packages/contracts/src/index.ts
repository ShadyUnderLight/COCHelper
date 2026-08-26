export {
  APP_HEALTH_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  REQUEST_ID_MAX_LENGTH,
  DESKTOP_BRIDGE_KEYS,
  isCancelRequest,
  isRequestId,
  type AppHealthRequest,
  type AppHealthPayload,
  type AppHealthResponse,
  type CancelRequest,
  type DesktopBridge,
  type RequestId,
} from './ipc';
export {
  DIAGNOSTIC_SEVERITIES,
  IPC_ERROR_KINDS,
  isIpcError,
  isResult,
  resultErr,
  resultOk,
} from './result';
export type { DiagnosticSeverity, IpcDiagnostic, IpcError, IpcErrorKind, Result } from './result';
export {
  IPC_DIAGNOSTIC_MAX_LENGTH,
  isSafeIpcDiagnosticText,
  isSafeIpcIdentifier,
  isSafeIpcPath,
  redactIpcDiagnosticText,
} from './safe-text';
