const MAX_DIAGNOSTIC_LENGTH = 200;

/** 清洗可展示错误文本，禁止 URL、凭据和控制字符进入 IPC envelope。 */
export function redactDiagnosticText(value: string): string {
  const redacted = value
    .replace(/https?:\/\/[^\s]+/gi, '[REDACTED_URL]')
    .replace(/\bauthorization\s*:\s*bearer\s+\S+/gi, 'authorization: [REDACTED]')
    .replace(/\bbearer\s+\S+/gi, 'Bearer [REDACTED]')
    .replace(
      /(["']?(?:token|api[-_]?key|password|secret)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}]+)/gi,
      '$1[REDACTED]',
    )
    .split('')
    .map((character) => {
      const code = character.charCodeAt(0);
      return code <= 0x1f || code === 0x7f ? ' ' : character;
    })
    .join('')
    .trim();
  return redacted.length > MAX_DIAGNOSTIC_LENGTH
    ? `${redacted.slice(0, MAX_DIAGNOSTIC_LENGTH)}…`
    : redacted;
}
