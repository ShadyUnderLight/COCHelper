import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { loadGoldenManifest, readGoldenFixture } from './manifest';

type Disposition = {
  readonly id: string;
  readonly category: string;
  readonly status: string;
  readonly reason: string;
};

type VillageContract = {
  readonly issue: number;
  readonly cases: readonly {
    readonly id: string;
    readonly expectedOwner: string;
    readonly summary: string;
  }[];
  readonly dispositions: readonly Disposition[];
};

const root = process.cwd();

describe('village projection contract registration (#271)', () => {
  it('manifest 条目可读，owner 存在，deferred disposition 不得记为通过', () => {
    const entry = loadGoldenManifest(root).cases.find(
      (item) => item.id === 'projection/village-projection-contract',
    );
    expect(entry).toBeDefined();
    const fixture = readGoldenFixture(root, entry!) as VillageContract;
    expect(fixture.issue).toBe(271);
    expect(fixture.cases.length).toBeGreaterThan(0);

    for (const item of fixture.cases) {
      const ownerPath = resolve(root, item.expectedOwner);
      expect(existsSync(ownerPath), `missing owner for ${item.id}: ${item.expectedOwner}`).toBe(
        true,
      );
    }

    expect(fixture.dispositions.length).toBeGreaterThan(0);
    for (const disposition of fixture.dispositions) {
      expect(disposition.status).toBe('deferred');
      expect(disposition.reason.length).toBeGreaterThan(0);
      expect(disposition.status).not.toBe('pass');
    }
  });
});
