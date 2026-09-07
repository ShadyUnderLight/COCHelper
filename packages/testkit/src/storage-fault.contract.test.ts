import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { loadGoldenManifest, readGoldenFixture } from './manifest';

type StorageFaultContract = {
  readonly issue: number;
  readonly cases: readonly {
    readonly id: string;
    readonly expectedOwner: string;
    readonly summary: string;
  }[];
  readonly dispositions: readonly unknown[];
};

const root = process.cwd();

describe('storage fault contract registration (#275)', () => {
  it('manifest 条目可读，且 fault owner 文件存在', () => {
    const entry = loadGoldenManifest(root).cases.find(
      (item) => item.id === 'error/storage-fault-contract',
    );
    expect(entry).toBeDefined();
    const fixture = readGoldenFixture(root, entry!) as StorageFaultContract;
    expect(fixture.issue).toBe(275);
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
