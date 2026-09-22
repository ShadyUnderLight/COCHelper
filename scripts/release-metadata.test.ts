import { describe, expect, it } from 'vitest';

import { assertReleaseSourceClean, readReleaseMetadata, validateSemver } from './release-metadata.mjs';

const cleanSource = () => ({ commitSha: 'commit-280', dirty: false, untrackedInputs: [] });

describe('release metadata', () => {
  it('只接受 SemVer release version', () => {
    expect(validateSemver('1.2.3')).toBe('1.2.3');
    expect(validateSemver('1.2.3-rc.1+build.7')).toBe('1.2.3-rc.1+build.7');
    expect(() => validateSemver('1.2')).toThrow('SemVer');
  });

  it('注入 app、build、catalog 和 source provenance', () => {
    const metadata = readReleaseMetadata(
      process.cwd(),
      {
        COCHELPER_RELEASE_CHANNEL: 'pre-cutover',
        COCHELPER_RELEASE_VERSION: '1.2.3',
        COCHELPER_BUILD_NUMBER: '42',
      },
      () => cleanSource(),
    );

    expect(metadata).toMatchObject({
      protocol: 'cochelper-release-manifest-v1',
      release: { channel: 'pre-cutover', version: '1.2.3', buildNumber: '42' },
      app: { productName: 'COCHelper', version: '1.2.3', buildNumber: '42' },
      source: { commitSha: 'commit-280', dirty: false },
      catalog: {
        version: '18.400.13',
        schemaVersion: 3,
        gameVersion: '18.400.13',
        buildTag: '18_400_7',
        locale: 'zh-CN',
      },
    });
  });

  it('候选 channel 拒绝 dirty source', () => {
    const metadata = {
      release: { channel: 'candidate' },
      source: { dirty: true, untrackedInputs: ['apps/desktop/src/generated.ts'] },
    } as never;
    expect(() => assertReleaseSourceClean(metadata)).toThrow('clean checkout');
  });
});
