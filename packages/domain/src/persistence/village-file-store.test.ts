import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { createVillageProfile } from '../import/types';
import { encodeVillageStoreBytes, loadVillageStoreBytes } from './village-codec';
import { VillageFileStore } from './village-file-store';

describe('village store codec', () => {
  it('区分 missing / loaded / corrupt / unsupportedSchema', () => {
    expect(loadVillageStoreBytes(null)).toEqual({ kind: 'missing' });

    const villages = [createVillageProfile({ id: 'v-a', name: 'A' })];
    const bytes = encodeVillageStoreBytes(villages);
    const loaded = loadVillageStoreBytes(bytes);
    expect(loaded.kind).toBe('loaded');
    if (loaded.kind === 'loaded') {
      expect(loaded.villages).toHaveLength(1);
      expect(loaded.villages[0]?.name).toBe('A');
    }

    const corrupt = loadVillageStoreBytes(new TextEncoder().encode('{'));
    expect(corrupt.kind).toBe('corrupt');

    const future = loadVillageStoreBytes(
      new TextEncoder().encode(JSON.stringify({ schemaVersion: 99, villages: [] })),
    );
    expect(future.kind).toBe('unsupportedSchema');
    if (future.kind === 'unsupportedSchema') {
      expect(future.schemaVersion).toBe(99);
    }
  });

  it('空数组是合法 loaded 而非 corrupt', () => {
    const result = loadVillageStoreBytes(new TextEncoder().encode('[]'));
    expect(result.kind).toBe('loaded');
    if (result.kind === 'loaded') {
      expect(result.villages).toEqual([]);
    }
  });
});

describe('VillageFileStore', () => {
  it('save/load 往返且 corrupt 不覆盖', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-villages-'));
    const fileURL = join(directory, 'villages-v1.json');
    const store = new VillageFileStore(fileURL);
    store.save([createVillageProfile({ id: 'v-1', name: '主村' })]);
    const loaded = store.load();
    expect(loaded.kind).toBe('loaded');

    const raw = store.readData();
    expect(raw).not.toBeNull();
    writeFileSync(fileURL, '{');
    expect(store.load().kind).toBe('corrupt');
    if (raw !== null) {
      store.restoreData(raw);
      expect(store.load().kind).toBe('loaded');
      expect(readFileSync(fileURL, 'utf8')).toBe(new TextDecoder().decode(raw));
    }
    rmSync(directory, { recursive: true, force: true });
  });

  it('reset 会先写入 recovery 再落空列表', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-villages-reset-'));
    const fileURL = join(directory, 'villages-v1.json');
    const store = new VillageFileStore(fileURL);
    store.save([createVillageProfile({ id: 'v-1', name: '主村' })]);
    store.reset([]);
    expect(store.load()).toEqual({ kind: 'loaded', villages: [] });
    expect(readFileSync(join(directory, 'villages-v1.recovery.json'), 'utf8').length).toBeGreaterThan(
      0,
    );
    rmSync(directory, { recursive: true, force: true });
  });
});
