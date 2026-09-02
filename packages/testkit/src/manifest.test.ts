import { describe, expect, it } from 'vitest';

import { fixturePath, loadGoldenManifest, readGoldenFixture } from './manifest';

const root = process.cwd();

describe('golden manifest', () => {
  it('加载当前 manifest 并验证每个 fixture fingerprint', () => {
    const manifest = loadGoldenManifest(root);
    expect(manifest.protocolVersion).toBe(1);
    expect(manifest.fixtureVersion).toBe('wire-contract-v1');
    expect(manifest.cases.length).toBeGreaterThanOrEqual(10);
    expect(new Set(manifest.cases.map((entry) => entry.id)).size).toBe(manifest.cases.length);
    for (const entry of manifest.cases) {
      expect(fixturePath(root, entry)).toContain(root);
      expect(readGoldenFixture(root, entry)).toBeDefined();
    }
  });
});
