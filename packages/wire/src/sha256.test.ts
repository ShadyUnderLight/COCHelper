import { describe, expect, it } from 'vitest';

import { isSha256Fingerprint, sha256Fingerprint } from './sha256';

describe('SHA-256 fingerprint（WA-3）', () => {
  it('空输入是已知向量，且格式为 sha256: + 64 小写 hex', () => {
    const fingerprint = sha256Fingerprint(new Uint8Array());
    expect(fingerprint).toBe(
      'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(fingerprint.length).toBe(71);
    expect(isSha256Fingerprint(fingerprint)).toBe(true);
  });

  it('拒绝大写 hex、缺前缀和错误长度', () => {
    expect(
      isSha256Fingerprint('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'),
    ).toBe(false);
    expect(
      isSha256Fingerprint(
        'sha256:E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855',
      ),
    ).toBe(false);
    expect(isSha256Fingerprint('sha256:deadbeef')).toBe(false);
  });
});
