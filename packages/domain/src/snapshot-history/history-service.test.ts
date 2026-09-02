import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account/parser';
import { createVillageProfile } from '../import/types';
import {
  createInMemorySnapshotHistoryStore,
  createSnapshotHistoryService,
  envelopeIsMigrated,
} from './index';

const GOLDEN_IMPORTED_AT_REF_SECONDS = 807_529_133;

class GoldenClock {
  nowMs(): number {
    return (GOLDEN_IMPORTED_AT_REF_SECONDS + 978_307_200) * 1000;
  }
}

describe('snapshot history service', () => {
  it('loadOrMigrate 从村庄快照种子化 envelope', () => {
    const root = resolve(process.cwd());
    const goldenText = readFileSync(
      resolve(root, 'Tests/Golden/Fixtures/account_snapshot_golden.json'),
      'utf8',
    );
    const parsed = parseAccountSnapshot(goldenText, { clock: new GoldenClock() });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) {
      return;
    }

    const villageID = parseUuid('00000000-0000-0000-0000-000000000001')!;
    const store = createInMemorySnapshotHistoryStore();
    const service = createSnapshotHistoryService(store);

    const migrated = service.loadOrMigrate({
      villages: [
        createVillageProfile({
          id: villageID,
          name: 'Test Village',
          accountSnapshot: parsed.value,
        }),
      ],
      nowRefSeconds: 807_629_133,
    });

    expect(envelopeIsMigrated(migrated)).toBe(true);
    expect(migrated.entries).toHaveLength(1);
    expect(migrated.lineages).toHaveLength(1);

    const again = service.loadOrMigrate({
      villages: [],
      nowRefSeconds: 807_729_133,
    });
    expect(again.entries).toHaveLength(1);
  });
});
