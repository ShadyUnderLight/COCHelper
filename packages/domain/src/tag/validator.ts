/** 官方 tag 规范化与格式校验（对齐 OfficialPlayerTagValidator.swift）。 */

/** 去掉首尾空白；空串或 null/undefined 返回 undefined。 */
export function normalizedTag(raw: string | null | undefined): string | undefined {
  if (raw === null || raw === undefined) {
    return undefined;
  }
  const trimmed = raw.trim();
  return trimmed.length === 0 ? undefined : trimmed;
}

/** 校验 tag 格式：`#` + 大写字母/数字 body，body ≤ 14。 */
export function isValidTag(tag: string): boolean {
  if (!tag.startsWith('#')) {
    return false;
  }
  const rest = tag.slice(1);
  if (rest.length === 0 || rest.length > 14) {
    return false;
  }
  return [...rest].every((character) => {
    const code = character.charCodeAt(0);
    const isUpper = code >= 65 && code <= 90;
    const isDigit = code >= 48 && code <= 57;
    return isUpper || isDigit;
  });
}

/** 跨档案拦截键：trim 后去 `#` 再 uppercased。 */
export function interceptKey(tag: string | null | undefined): string | undefined {
  const normalized = normalizedTag(tag);
  if (normalized === undefined) {
    return undefined;
  }
  const body = normalized.startsWith('#') ? normalized.slice(1) : normalized;
  return body.toUpperCase();
}
