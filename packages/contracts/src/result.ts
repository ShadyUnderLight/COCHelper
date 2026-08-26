import { isSafeIpcDiagnosticText, isSafeIpcIdentifier, isSafeIpcPath } from './safe-text';

export const IPC_ERROR_KINDS = [
  'validation',
  'internal',
  'cancelled',
  'missingCredentials',
  'unauthorized',
  'accessDenied',
  'notFound',
  'rateLimited',
  'serverError',
  'timeout',
  'network',
  'malformedResponse',
] as const;

export type IpcErrorKind = (typeof IPC_ERROR_KINDS)[number];

export const DIAGNOSTIC_SEVERITIES = ['info', 'warning', 'error'] as const;

export type DiagnosticSeverity = (typeof DIAGNOSTIC_SEVERITIES)[number];

/** 可跨 IPC 传递的本地化诊断；messageKey 保持稳定，message 可随语言变化。 */
export type IpcDiagnostic = {
  readonly severity: DiagnosticSeverity;
  readonly code: string;
  readonly messageKey: string;
  readonly message: string;
  readonly path?: string;
};

/** IPC 错误的安全 envelope，不包含原始 Error、stack、请求或响应内容。 */
export type IpcError = {
  readonly kind: IpcErrorKind;
  readonly code: string;
  readonly messageKey: string;
  readonly message: string;
  readonly diagnostics?: readonly IpcDiagnostic[];
};

export type Result<T, E = IpcError> =
  { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: E };

export function resultOk<T>(value: T): Result<T, never> {
  return { ok: true, value };
}

export function resultErr<E>(error: E): Result<never, E> {
  return { ok: false, error };
}

export function isIpcError(value: unknown): value is IpcError {
  if (
    !isRecord(value) ||
    !hasOnlyKeys(value, ['kind', 'code', 'messageKey', 'message', 'diagnostics']) ||
    !hasOwnKeys(value, ['kind', 'code', 'messageKey', 'message'])
  ) {
    return false;
  }
  if (
    !isIpcErrorKind(value.kind) ||
    !isSafeIpcIdentifier(value.code) ||
    !isSafeIpcIdentifier(value.messageKey) ||
    !isSafeIpcDiagnosticText(value.message)
  ) {
    return false;
  }
  return !Object.hasOwn(value, 'diagnostics') || isDiagnostics(value.diagnostics);
}

export function isResult<T, E>(
  value: unknown,
  isValue: (value: unknown) => value is T,
  isError: (value: unknown) => value is E,
): value is Result<T, E> {
  if (!isRecord(value)) {
    return false;
  }
  if (value.ok === true) {
    return (
      hasOnlyKeys(value, ['ok', 'value']) &&
      Object.hasOwn(value, 'ok') &&
      Object.hasOwn(value, 'value') &&
      isValue(value.value)
    );
  }
  if (value.ok === false) {
    return (
      hasOnlyKeys(value, ['ok', 'error']) &&
      Object.hasOwn(value, 'ok') &&
      Object.hasOwn(value, 'error') &&
      isError(value.error)
    );
  }
  return false;
}

function isDiagnostics(value: unknown): value is readonly IpcDiagnostic[] {
  return (
    Array.isArray(value) &&
    value.every(
      (diagnostic) =>
        isRecord(diagnostic) &&
        hasOnlyKeys(diagnostic, ['severity', 'code', 'messageKey', 'message', 'path']) &&
        hasOwnKeys(diagnostic, ['severity', 'code', 'messageKey', 'message']) &&
        isDiagnosticSeverity(diagnostic.severity) &&
        isSafeIpcIdentifier(diagnostic.code) &&
        isSafeIpcIdentifier(diagnostic.messageKey) &&
        isSafeIpcDiagnosticText(diagnostic.message) &&
        (!Object.hasOwn(diagnostic, 'path') || isSafeIpcPath(diagnostic.path)),
    )
  );
}

function isIpcErrorKind(value: unknown): value is IpcErrorKind {
  return typeof value === 'string' && (IPC_ERROR_KINDS as readonly string[]).includes(value);
}

function isDiagnosticSeverity(value: unknown): value is DiagnosticSeverity {
  return typeof value === 'string' && (DIAGNOSTIC_SEVERITIES as readonly string[]).includes(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || value instanceof Error) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const allowed = new Set(keys);
  return Reflect.ownKeys(value).every((key) => typeof key === 'string' && allowed.has(key));
}

function hasOwnKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return keys.every((key) => Object.hasOwn(value, key));
}
