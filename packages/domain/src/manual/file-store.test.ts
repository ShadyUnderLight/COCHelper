import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { parseUuid } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import {
  createInMemoryManualTrackerStore,
  FileManualTrackerStore,
} from '../manual/file-store';
import {
  emptyManualTrackerEnvelope,
  createManualTrackerEnvelope,
} from '../manual/tracker-envelope';
import {
  decodeManualTrackerEnvelopeWire,
  encodeManualTrackerEnvelopeWire,
} from '../manual/tracker-wire';

describe('manual tracker wire', () => {
  it('空 envelope 与带空 core 村庄可往返', () => {
    const empty = createManualTrackerEnvelope({});
    const emptyDecoded = decodeManualTrackerEnvelopeWire(
      encodeManualTrackerEnvelopeWire(empty),
    );
    expect(emptyDecoded.villages).toEqual([]);

    const villageID = parseUuid('00000000-0000-0000-0000-000000000031')!;
    const seeded = emptyManualTrackerEnvelope([villageID], 1_000);
    const decoded = decodeManualTrackerEnvelopeWire(encodeManualTrackerEnvelopeWire(seeded));
    expect(decoded.villages).toHaveLength(1);
    expect(decoded.villages[0]?.villageID).toBe(villageID);
    expect(decoded.migrationMarker?.completedAtMs).toBe(1_000);
  });
});

describe('FileManualTrackerStore', () => {
  it('missing 返回 null；corrupt 不覆盖旧文件', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-manual-'));
    const fileURL = join(directory, 'manual-tracker-v1.json');
    const store = new FileManualTrackerStore(fileURL);
    expect(store.load()).toBeNull();

    const villageID = parseUuid('00000000-0000-0000-0000-000000000041')!;
    store.save(emptyManualTrackerEnvelope([villageID], 2_000));
    expect(store.load()?.villages).toHaveLength(1);

    const raw = store.readRawData();
    writeFileSync(fileURL, '{');
    expect(() => store.load()).toThrow();
    if (raw !== null) {
      store.restoreRawData(raw);
      expect(store.load()?.villages[0]?.villageID).toBe(villageID);
    }
    rmSync(directory, { recursive: true, force: true });
  });

  it('内存 store 支持事务用 raw 快照', () => {
    const store = createInMemoryManualTrackerStore();
    store.save(createManualTrackerEnvelope({}));
    expect(store.snapshot()).not.toBeNull();
  });
});
