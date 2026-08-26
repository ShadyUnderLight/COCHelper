const SECRET_PATTERNS: ReadonlyArray<{ re: RegExp; message: string }> = [
  { re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/, message: '私钥块' },
  { re: /Authorization:\s*Bearer\s+\S+/i, message: 'Authorization Bearer' },
  { re: /\bCookie:\s*\S+/i, message: 'Cookie' },
  { re: /\bSet-Cookie:\s*\S+/i, message: 'Set-Cookie' },
  { re: /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}/, message: 'JWT' },
];

/** 规范化后的 JSON 键；覆盖 header 名与常见 token 字段，不靠值的形态。 */
const SENSITIVE_JSON_KEYS = new Set([
  'cookie',
  'setcookie',
  'authorization',
  'accesstoken',
  'refreshtoken',
  'apitoken',
  'token',
]);

/** 匿名 fixture 允许的 Tag 前缀；其余 Clash Tag 字符集命中视为真实 Tag。 */
const ANONYMOUS_TAG = /^#(GOLDEN|TEST|CLANANON|PLAYERANON)/i;
const COC_TAG = /#[0289PYLQGRJCUV]{3,15}\b/gi;

export function normalizeSecretKey(key: string): string {
  return key.toLowerCase().replace(/[-_]/g, '');
}

export function isSensitiveJsonKey(key: string): boolean {
  return SENSITIVE_JSON_KEYS.has(normalizeSecretKey(key));
}

export function findSensitiveJsonKeys(value: unknown, label: string, path = '$'): string[] {
  const hits: string[] = [];
  walkJson(value, label, path, hits);
  return hits;
}

export function findFixtureSecretHits(text: string, label: string): string[] {
  const hits: string[] = [];
  for (const pattern of SECRET_PATTERNS) {
    if (pattern.re.test(text)) {
      hits.push(`${label} → ${pattern.message}`);
    }
  }
  for (const match of text.matchAll(COC_TAG)) {
    const tag = match[0];
    if (!ANONYMOUS_TAG.test(tag)) {
      hits.push(`${label} → 真实 Tag ${tag}`);
    }
  }
  const parsed = tryParseJson(text);
  if (parsed !== undefined) {
    hits.push(...findSensitiveJsonKeys(parsed, label));
  }
  return hits;
}

export function assertGoldenPayloadSafe(text: string, label: string): void {
  const hits = findFixtureSecretHits(text, label);
  if (hits.length > 0) {
    throw new Error(`golden fixture 含敏感信息：\n${hits.join('\n')}`);
  }
}

function walkJson(value: unknown, label: string, path: string, hits: string[]): void {
  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      walkJson(item, label, `${path}[${index}]`, hits);
    });
    return;
  }
  if (value === null || typeof value !== 'object') {
    return;
  }
  for (const [key, child] of Object.entries(value)) {
    const childPath = `${path}.${key}`;
    if (isSensitiveJsonKey(key)) {
      hits.push(`${label} → JSON 敏感键 ${childPath}`);
    }
    walkJson(child, label, childPath, hits);
  }
}

function tryParseJson(text: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
}
