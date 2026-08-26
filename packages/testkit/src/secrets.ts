const SECRET_PATTERNS: ReadonlyArray<{ re: RegExp; message: string }> = [
  { re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/, message: '私钥块' },
  { re: /Authorization:\s*Bearer\s+\S+/i, message: 'Authorization Bearer' },
  { re: /\bCookie:\s*\S+/i, message: 'Cookie' },
  { re: /\bSet-Cookie:\s*\S+/i, message: 'Set-Cookie' },
  { re: /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}/, message: 'JWT' },
];

/** 匿名 fixture 允许的 Tag 前缀；其余 Clash Tag 字符集命中视为真实 Tag。 */
const ANONYMOUS_TAG = /^#(GOLDEN|TEST|CLANANON|PLAYERANON)/i;
const COC_TAG = /#[0289PYLQGRJCUV]{3,15}\b/gi;

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
  return hits;
}

export function assertGoldenPayloadSafe(text: string, label: string): void {
  const hits = findFixtureSecretHits(text, label);
  if (hits.length > 0) {
    throw new Error(`golden fixture 含敏感信息：\n${hits.join('\n')}`);
  }
}
