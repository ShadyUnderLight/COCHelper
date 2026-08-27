import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { assertGoldenFixtureClosure, isIgnoredGoldenFixtureName } from './manifest';

describe('golden fixture 闭包', () => {
  it('只忽略明确的非 fixture 点文件，未登记的 .fixture.json 必须失败', () => {
    expect(isIgnoredGoldenFixtureName('.DS_Store')).toBe(true);
    expect(isIgnoredGoldenFixtureName('Thumbs.db')).toBe(true);
    expect(isIgnoredGoldenFixtureName('.fixture.json')).toBe(false);

    const root = mkdtempSync(path.join(os.tmpdir(), 'golden-closure-'));
    const fixtures = path.join(root, 'Tests/Golden/Fixtures');
    mkdirSync(fixtures, { recursive: true });
    writeFileSync(path.join(fixtures, '.fixture.json'), '{}');
    writeFileSync(path.join(fixtures, '.DS_Store'), '');
    try {
      expect(() =>
        assertGoldenFixtureClosure({ schemaVersion: 1, description: '', fixtures: [] }, root),
      ).toThrow('golden manifest 未登记 Fixtures 文件：.fixture.json');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
