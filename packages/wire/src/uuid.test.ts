import { describe, expect, it } from 'vitest';

import { generateUuid, isCanonicalUuidString, parseUuid } from './uuid';

describe('UUID（WA-5）', () => {
  it('生成大写连字符形态', () => {
    const id = generateUuid();
    expect(isCanonicalUuidString(id)).toBe(true);
    expect(id).toBe(id.toUpperCase());
  });

  it('解析大小写并规范化为大写；非法值拒绝', () => {
    expect(parseUuid('00000000-0000-0000-0000-000000000001')).toBe(
      '00000000-0000-0000-0000-000000000001',
    );
    expect(parseUuid('00000000-0000-0000-0000-00000000000a')).toBe(
      '00000000-0000-0000-0000-00000000000A',
    );
    expect(isCanonicalUuidString('00000000-0000-0000-0000-00000000000a')).toBe(false);
    expect(parseUuid('not-a-uuid')).toBeUndefined();
    expect(parseUuid('00000000000000000000000000000001')).toBeUndefined();
  });
});
