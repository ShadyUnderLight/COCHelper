import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { loadGoldenManifest, readGoldenFixture } from './manifest';

type CatalogContract = {
  readonly issue: number;
  readonly cases: readonly {
    readonly id: string;
    readonly expectedOwner: string;
    readonly summary: string;
  }[];
  readonly dispositions: readonly unknown[];
};

const root = process.cwd();

describe('catalog contract registration (#270)', () => {
  it('manifest 条目可读，且 expectedOwner 文件存在', () => {
    const entry = loadGoldenManifest(root).cases.find(
      (item) => item.id === 'projection/catalog-contract',
    );
    expect(entry).toBeDefined();
    const fixture = readGoldenFixture(root, entry!) as CatalogContract;
    expect(fixture.issue).toBe(270);
    expect(fixture.cases.length).toBeGreaterThan(0);
    expect(fixture.dispositions).toEqual([]);

    for (const item of fixture.cases) {
      const ownerPath = resolve(root, item.expectedOwner);
      expect(existsSync(ownerPath), `missing owner for ${item.id}: ${item.expectedOwner}`).toBe(
        true,
      );
    }
  });
});
