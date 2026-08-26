export const IPC_DIAGNOSTIC_MAX_LENGTH = 200;

const STRUCTURED_JSON_MAX_LENGTH = 32_768;
const IPC_IDENTIFIER_MAX_LENGTH = 64;
const IPC_PATH_MAX_LENGTH = 128;
const SAFE_IDENTIFIER = /^[A-Za-z][A-Za-z0-9]*(?:[._-][A-Za-z0-9]+)*$/;
const SAFE_PATH =
  /^[A-Za-z_][A-Za-z0-9_]*(?:(?:\.[A-Za-z_][A-Za-z0-9_]*)|(?:\[(?:0|[1-9][0-9]*)\]))*$/;
const JSON_CREDENTIAL_HEADER =
  /(["'])(authorization|proxy-authorization|cookie|set-cookie)\1\s*[:=]\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\r\n,}]+)/gi;
const PLAIN_CREDENTIAL_HEADER =
  /\b(authorization|proxy-authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]*/gi;
const KEY_VALUE_CREDENTIAL =
  /(["']?(?:token|api[-_]?key|password|secret)["']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;}]+)/gi;
const URL_PATTERN = /https?:\\?\/\\?[^\s"']+/gi;

const SENSITIVE_HEADER_NAMES = new Set([
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
]);

/** 清洗 IPC 可展示文本，并移除结构化或普通文本中的凭据。 */
export function redactIpcDiagnosticText(value: string): string {
  const structured = redactStructuredJson(value);
  const redacted = redactPlainText(structured.value)
    .split('')
    .map((character) => {
      const code = character.charCodeAt(0);
      return code <= 0x1f || code === 0x7f ? ' ' : character;
    })
    .join('')
    .trim();

  return redacted.length > IPC_DIAGNOSTIC_MAX_LENGTH
    ? `${redacted.slice(0, IPC_DIAGNOSTIC_MAX_LENGTH - 1)}…`
    : redacted;
}

function redactPlainText(value: string): string {
  return value
    .replace(JSON_CREDENTIAL_HEADER, (match: string, _quote: string, header: string) =>
      isAlreadyRedactedHeader(match) ? match : `${canonicalHeaderName(header)}: [REDACTED]`,
    )
    .replace(PLAIN_CREDENTIAL_HEADER, (match: string, header: string) =>
      isAlreadyRedactedHeader(match) ? match : `${canonicalHeaderName(header)}: [REDACTED]`,
    )
    .replace(URL_PATTERN, '[REDACTED_URL]')
    .replace(/\bbearer\s+\S+/gi, 'Bearer [REDACTED]')
    .replace(KEY_VALUE_CREDENTIAL, '$1[REDACTED]');
}

/** 只接受可安全跨 IPC 传递的、稳定格式的 code/messageKey。 */
export function isSafeIpcIdentifier(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= IPC_IDENTIFIER_MAX_LENGTH &&
    SAFE_IDENTIFIER.test(value)
  );
}

/** 只接受对象字段和数组下标组成的受限诊断路径。 */
export function isSafeIpcPath(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= IPC_PATH_MAX_LENGTH &&
    SAFE_PATH.test(value)
  );
}

/** 诊断文本必须已经是清洗后的规范形态。 */
export function isSafeIpcDiagnosticText(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= IPC_DIAGNOSTIC_MAX_LENGTH &&
    redactIpcDiagnosticText(value) === value
  );
}

type StructuredRedaction = {
  readonly value: string;
};

function redactStructuredJson(value: string): StructuredRedaction {
  const trimmed = value.trim();
  if (value.length > STRUCTURED_JSON_MAX_LENGTH || (trimmed[0] !== '{' && trimmed[0] !== '[')) {
    return { value };
  }

  try {
    const parsed: unknown = JSON.parse(trimmed);
    let changed = false;
    const sanitized = redactJsonValue(parsed, () => {
      changed = true;
    });
    return {
      value: changed ? JSON.stringify(sanitized) : value,
    };
  } catch {
    return { value };
  }
}

function redactJsonValue(value: unknown, markChanged: () => void): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => redactJsonValue(item, markChanged));
  }
  if (typeof value === 'string') {
    const sanitized = redactPlainText(value);
    if (sanitized !== value) {
      markChanged();
    }
    return sanitized;
  }
  if (typeof value !== 'object' || value === null) {
    return value;
  }

  const sanitized: Record<string, unknown> = Object.create(null);
  for (const key of Object.keys(value)) {
    if (SENSITIVE_HEADER_NAMES.has(key.toLowerCase())) {
      markChanged();
      sanitized[key] = '[REDACTED]';
    } else {
      sanitized[key] = redactJsonValue((value as Record<string, unknown>)[key], markChanged);
    }
  }
  return sanitized;
}

function isAlreadyRedactedHeader(value: string): boolean {
  return /[:=]\s*["']?\[REDACTED(?:_[A-Z]+)?\]["']?\s*$/i.test(value);
}

function canonicalHeaderName(value: string): string {
  switch (value.toLowerCase()) {
    case 'authorization':
      return 'Authorization';
    case 'proxy-authorization':
      return 'Proxy-Authorization';
    case 'cookie':
      return 'Cookie';
    case 'set-cookie':
      return 'Set-Cookie';
    default:
      return 'Header';
  }
}
