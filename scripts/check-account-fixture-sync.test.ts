import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { afterEach, describe, expect, it } from 'vitest';

import { assertFixtureSync, checkFixtureSync } from './check-account-fixture-sync.mjs';

describe('account fixture sync gate', () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('接受内容和文件集合完全一致的目录', () => {
    const root = mkdtempSync(path.join(tmpdir(), 'coc-account-fixture-sync-'));
    roots.push(root);
    const electron = path.join(root, 'electron');
    const swift = path.join(root, 'swift');
    mkdirSync(path.join(electron, 'nested'), { recursive: true });
    mkdirSync(path.join(swift, 'nested'), { recursive: true });
    writeFileSync(path.join(electron, 'a.json'), '{"a":1}\n');
    writeFileSync(path.join(swift, 'a.json'), '{"a":1}\n');
    writeFileSync(path.join(electron, 'nested', 'b.json'), '{"b":2}\n');
    writeFileSync(path.join(swift, 'nested', 'b.json'), '{"b":2}\n');

    expect(checkFixtureSync(electron, swift)).toEqual({
      missingInElectron: [],
      missingInSwift: [],
      mismatched: [],
    });
    expect(assertFixtureSync(electron, swift)).toEqual({
      missingInElectron: [],
      missingInSwift: [],
      mismatched: [],
    });
  });

  it('拒绝缺失文件和内容漂移', () => {
    const root = mkdtempSync(path.join(tmpdir(), 'coc-account-fixture-sync-'));
    roots.push(root);
    const electron = path.join(root, 'electron');
    const swift = path.join(root, 'swift');
    mkdirSync(electron, { recursive: true });
    mkdirSync(swift, { recursive: true });
    writeFileSync(path.join(electron, 'only-electron.json'), '{}');
    writeFileSync(path.join(electron, 'changed.json'), '{"version":2}');
    writeFileSync(path.join(swift, 'only-swift.json'), '{}');
    writeFileSync(path.join(swift, 'changed.json'), '{"version":1}');

    expect(checkFixtureSync(electron, swift)).toEqual({
      missingInElectron: ['only-swift.json'],
      missingInSwift: ['only-electron.json'],
      mismatched: ['changed.json'],
    });
    expect(() => assertFixtureSync(electron, swift)).toThrow(
      /Electron\/Swift account fixture 不一致/,
    );
  });
});
