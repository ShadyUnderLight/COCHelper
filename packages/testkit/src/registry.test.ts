import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { isVitestExecutedOwner, loadTestRegistry } from './registry';

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

  it('解析 swift 路径后仍必须位于 Tests/ 且指向存在的 Swift 文件', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'test-registry-'));
    try {
      mkdirSync(path.join(root, 'Tests/Golden'), { recursive: true });
      mkdirSync(path.join(root, 'packages/testkit'), { recursive: true });
      writeFileSync(path.join(root, 'Package.swift'), '// forged owner\n');
      writeFileSync(
        path.join(root, 'packages/testkit/registry.json'),
        JSON.stringify({
          schemaVersion: 1,
          description: 'test',
          tests: [
            {
              id: 'forged',
              swift: 'Tests/../Package.swift',
              category: 'parser',
              ownerIssue: 1,
              tsOwner: null,
              status: 'unported',
              loadBearing: true,
            },
          ],
        }),
      );

      expect(() => loadTestRegistry(root)).toThrow('解析后必须位于 Tests/ 内');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('拒绝 Tests/ 内指向外部的 Swift symlink', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'test-registry-symlink-'));
    try {
      mkdirSync(path.join(root, 'Tests/Golden'), { recursive: true });
      mkdirSync(path.join(root, 'packages/testkit'), { recursive: true });
      writeFileSync(path.join(root, 'Package.swift'), '// outside Tests\n');
      symlinkSync(path.join(root, 'Package.swift'), path.join(root, 'Tests/Fake.swift'));
      writeFileSync(
        path.join(root, 'packages/testkit/registry.json'),
        JSON.stringify({
          schemaVersion: 1,
          description: 'test',
          tests: [
            {
              id: 'symlink',
              swift: 'Tests/Fake.swift',
              category: 'parser',
              ownerIssue: 1,
              tsOwner: null,
              status: 'unported',
              loadBearing: true,
            },
          ],
        }),
      );

      expect(() => loadTestRegistry(root)).toThrow('解析后必须位于 Tests/ 内');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('拒绝仓库内伪装成测试文件的 tsOwner symlink', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'test-registry-ts-owner-'));
    try {
      mkdirSync(path.join(root, 'Tests/Golden'), { recursive: true });
      mkdirSync(path.join(root, 'packages/testkit/src'), { recursive: true });
      writeFileSync(path.join(root, 'Tests/Owner.swift'), '// owner\n');
      writeFileSync(path.join(root, 'packages/testkit/src/index.ts'), 'export const index = 1;\n');
      symlinkSync(
        path.join(root, 'packages/testkit/src/index.ts'),
        path.join(root, 'packages/testkit/src/ported.test.ts'),
      );
      writeFileSync(
        path.join(root, 'packages/testkit/registry.json'),
        JSON.stringify({
          schemaVersion: 1,
          description: 'test',
          tests: [
            {
              id: 'ts-owner-symlink',
              swift: 'Tests/Owner.swift',
              category: 'parser',
              ownerIssue: 1,
              tsOwner: 'packages/testkit/src/ported.test.ts',
              status: 'ported',
              loadBearing: true,
            },
          ],
        }),
      );

      expect(() => loadTestRegistry(root)).toThrow('tsOwner 不得是 symlink');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
