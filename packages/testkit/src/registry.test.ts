import { describe, expect, it } from 'vitest';

import { isVitestExecutedOwner } from './registry';

describe('test registry tsOwner', () => {
  it('拒绝 package.json 与非测试源码，只接受 Vitest 会跑的测试文件', () => {
    expect(isVitestExecutedOwner('package.json')).toBe(false);
    expect(isVitestExecutedOwner('packages/testkit/package.json')).toBe(false);
    expect(isVitestExecutedOwner('packages/testkit/src/index.ts')).toBe(false);
    expect(isVitestExecutedOwner('packages/testkit/src/compare.ts')).toBe(false);
    expect(isVitestExecutedOwner('../packages/testkit/src/index.test.ts')).toBe(false);
    expect(isVitestExecutedOwner('apps/desktop/src/main/ipc.parity.test.ts')).toBe(false);

    expect(isVitestExecutedOwner('packages/testkit/src/canonical-json.parity.test.ts')).toBe(true);
    expect(isVitestExecutedOwner('packages/wire/src/saturating.test.ts')).toBe(true);
    expect(isVitestExecutedOwner('apps/desktop/src/main/redaction.test.ts')).toBe(true);
    expect(isVitestExecutedOwner('scripts/check-testkit-isolation.test.ts')).toBe(true);
    expect(isVitestExecutedOwner('packages/testkit/src/fault.replay.test.ts')).toBe(true);
  });
});
