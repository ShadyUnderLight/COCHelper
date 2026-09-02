import { readdirSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { fixturePath, loadGoldenManifest, readGoldenFixture } from './manifest';

const root = process.cwd();
const FIXTURES_DIR = 'Tests/Golden/Fixtures';

describe('golden manifest', () => {
  it('Fixtures 目录与 manifest 一一对应，并验证每个 fixture fingerprint', () => {
    const manifest = loadGoldenManifest(root);
    expect(manifest.protocolVersion).toBe(1);
    expect(manifest.fixtureVersion).toBe('wire-contract-v1');
    expect(new Set(manifest.cases.map((entry) => entry.id)).size).toBe(manifest.cases.length);

    const fixtureFiles = readdirSync(resolve(root, FIXTURES_DIR))
      .filter((name) => name.endsWith('.json'))
      .map((name) => `${FIXTURES_DIR}/${name}`)
      .sort();
    const manifestFiles = manifest.cases.map((entry) => entry.fixture).sort();
    expect(manifestFiles).toEqual(fixtureFiles);

    for (const entry of manifest.cases) {
      expect(fixturePath(root, entry)).toContain(root);
      expect(readGoldenFixture(root, entry)).toBeDefined();
    }
  });
});
