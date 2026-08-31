import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account';
import {
  applySnapshotToVillage,
  createVillageProfile,
  prepareQuickImport,
  resolvePendingTarget,
} from '../import';
import { interceptKey, normalizedTag } from '../tag/validator';

class FakeClock {
  constructor(private readonly fixedMs: number) {}

  nowMs(): number {
    return this.fixedMs;
  }
}

function emptySnapshot(text = '{}') {
  const parsed = parseAccountSnapshot(text, { clock: new FakeClock(0) });
  if (!parsed.ok) {
    throw new Error('unexpected parse failure');
  }
  return parsed.value;
}

describe('import routing', () => {
  it('prepareQuickImport 成功时固定 targetVillageId', () => {
    const village = createVillageProfile({
      id: '00000000-0000-0000-0000-000000000001',
      name: 'A',
      accountSnapshot: emptySnapshot('{"tag":"#ABC","buildings":[]}'),
    });
    const result = prepareQuickImport({
      text: '{"tag":"#ABC","buildings":[]}',
      targetVillageId: village.id,
      villages: [village],
      clock: new FakeClock(0),
    });
    expect(result.ok).toBe(true);
    if (!result.ok) {
      return;
    }
    expect(result.value.targetVillageId).toBe(village.id);
    expect(result.value.replacesSameTag).toBe(true);
    expect(result.value.destinationDescription).toContain('更新');
  });

  it('JSON tag 命中其他村庄时拦截', () => {
    const a = createVillageProfile({
      id: '00000000-0000-0000-0000-000000000001',
      name: 'A',
      accountSnapshot: emptySnapshot('{"tag":"#ABC","buildings":[]}'),
    });
    const b = createVillageProfile({
      id: '00000000-0000-0000-0000-000000000002',
      name: 'B',
      accountSnapshot: emptySnapshot('{"tag":"#XYZ","buildings":[]}'),
    });
    const result = prepareQuickImport({
      text: '{"tag":"#ABC","buildings":[]}',
      targetVillageId: b.id,
      villages: [a, b],
      clock: new FakeClock(0),
    });
    expect(result).toEqual({
      ok: false,
      error: {
        kind: 'tagBelongsToAnotherVillage',
        tag: '#ABC',
        villageName: 'A',
      },
    });
  });

  it('interceptKey 忽略大小写与 # 前缀', () => {
    expect(interceptKey('#abc')).toBe('ABC');
    expect(interceptKey('abc')).toBe('ABC');
    expect(normalizedTag('#abc')).toBe('#abc');
  });

  it('resolvePendingTarget 对重复 tag 返回 ambiguous', () => {
    const villages = [
      createVillageProfile({
        id: '1',
        name: 'A',
        accountSnapshot: emptySnapshot('{"tag":"#DUP","buildings":[]}'),
      }),
      createVillageProfile({
        id: '2',
        name: 'B',
        accountSnapshot: emptySnapshot('{"tag":"#DUP","buildings":[]}'),
      }),
    ];
    const snapshot = emptySnapshot('{"tag":"#DUP","buildings":[]}');
    expect(
      resolvePendingTarget(snapshot, villages, {
        selectedVillageId: '1',
        importIntoCurrentVillage: false,
      }),
    ).toEqual({
      kind: 'ambiguous',
      tag: '#DUP',
      villageNames: ['A', 'B'],
    });
  });

  it('resolvePendingTarget 返回稳定 villageId 而非数组 index', () => {
    const villages = [
      createVillageProfile({ id: 'v-a', name: 'A' }),
      createVillageProfile({ id: 'v-b', name: 'B' }),
    ];
    const snapshot = emptySnapshot('{"tag":"#NEW","buildings":[]}');
    expect(
      resolvePendingTarget(snapshot, villages, {
        selectedVillageId: 'v-b',
        importIntoCurrentVillage: true,
      }),
    ).toEqual({ kind: 'existing', villageId: 'v-b' });
  });

  it('applySnapshotToVillage 在 tag 变化时清空 officialAPIState', () => {
    const village = createVillageProfile({
      id: '1',
      name: 'A',
      accountSnapshot: emptySnapshot('{"tag":"#OLD","buildings":[]}'),
      officialAPIState: { status: 'success' },
    });
    const next = applySnapshotToVillage(village, emptySnapshot('{"tag":"#NEW","buildings":[]}'));
    expect(next.officialAPIState).toBeNull();
    expect(next.tag).toBe('#NEW');
  });

  it('applySnapshotToVillage 同 tag 保留 officialAPIState', () => {
    const officialAPIState = { status: 'success' };
    const village = createVillageProfile({
      id: '1',
      name: 'A',
      accountSnapshot: emptySnapshot('{"tag":"#ABC","buildings":[]}'),
      officialAPIState,
    });
    const next = applySnapshotToVillage(village, emptySnapshot('{"tag":"#ABC","buildings":[]}'));
    expect(next.officialAPIState).toBe(officialAPIState);
  });
});
