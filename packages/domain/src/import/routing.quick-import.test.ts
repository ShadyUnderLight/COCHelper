import { describe, expect, it } from 'vitest';

import { parseAccountSnapshot } from '../account';
import {
  applySnapshotToVillage,
  createVillageProfile,
  parsePendingImport,
  prepareQuickImport,
  resolvePendingTarget,
} from './index';

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

describe('quick import routing parity', () => {
  it('空剪贴板 → emptyClipboard', () => {
    const village = createVillageProfile({ id: 'v-a', name: 'A' });
    expect(
      prepareQuickImport({
        text: '   \n',
        targetVillageId: village.id,
        villages: [village],
        clock: new FakeClock(0),
      }),
    ).toEqual({ ok: false, error: { kind: 'emptyClipboard' } });
  });

  it('目标村庄缺失 → targetVillageMissing', () => {
    const village = createVillageProfile({
      id: 'v-a',
      name: 'A',
      accountSnapshot: emptySnapshot('{"tag":"#A","buildings":[]}'),
    });
    expect(
      prepareQuickImport({
        text: '{"tag":"#A","buildings":[]}',
        targetVillageId: '00000000-0000-0000-0000-000000009999',
        villages: [village],
        clock: new FakeClock(0),
      }),
    ).toEqual({ ok: false, error: { kind: 'targetVillageMissing' } });
  });

  it('首次导入描述走「建立」分支', () => {
    const village = createVillageProfile({ id: 'v-a', name: 'A' });
    const result = prepareQuickImport({
      text: '{"tag":"#NEW","buildings":[]}',
      targetVillageId: village.id,
      villages: [village],
      clock: new FakeClock(0),
    });
    expect(result.ok).toBe(true);
    if (!result.ok) {
      return;
    }
    expect(result.value.targetVillageHasSnapshot).toBe(false);
    expect(result.value.destinationDescription).toBe('将建立「A」的账号快照并导入');
  });

  it('目标已有快照但无 Tag 时不是首次导入', () => {
    const village = createVillageProfile({
      id: 'v-a',
      name: 'A',
      accountSnapshot: emptySnapshot('{"buildings":[]}'),
    });
    const result = prepareQuickImport({
      text: '{"buildings":[]}',
      targetVillageId: village.id,
      villages: [village],
      clock: new FakeClock(0),
    });
    expect(result.ok).toBe(true);
    if (!result.ok) {
      return;
    }
    expect(result.value.targetVillageHasSnapshot).toBe(true);
    expect(result.value.destinationDescription).toContain('JSON 未提供账号 Tag');
    expect(result.value.destinationDescription).not.toContain('建立');
  });

  it('小写 tag 变体在双档案时拦截', () => {
    const a = createVillageProfile({
      id: 'v-a',
      name: 'A',
      accountSnapshot: emptySnapshot('{"tag":"#ABC","buildings":[]}'),
    });
    const b = createVillageProfile({
      id: 'v-b',
      name: 'B',
      accountSnapshot: emptySnapshot('{"tag":"#ABC","buildings":[]}'),
    });
    expect(
      prepareQuickImport({
        text: '{"tag":"#abc","buildings":[]}',
        targetVillageId: a.id,
        villages: [a, b],
        clock: new FakeClock(0),
      }),
    ).toEqual({
      ok: false,
      error: { kind: 'tagBelongsToAnotherVillage', tag: '#abc', villageName: 'B' },
    });
  });

  it('缺 # 变体在双档案时拦截', () => {
    const a = createVillageProfile({
      id: 'v-a',
      name: 'A',
      accountSnapshot: emptySnapshot('{"tag":"#ABC","buildings":[]}'),
    });
    const b = createVillageProfile({
      id: 'v-b',
      name: 'B',
      accountSnapshot: emptySnapshot('{"tag":"#ABC","buildings":[]}'),
    });
    expect(
      prepareQuickImport({
        text: '{"tag":"ABC","buildings":[]}',
        targetVillageId: a.id,
        villages: [a, b],
        clock: new FakeClock(0),
      }),
    ).toEqual({
      ok: false,
      error: { kind: 'tagBelongsToAnotherVillage', tag: 'ABC', villageName: 'B' },
    });
  });

  it('单档案小写 tag 变体不视为 same-tag', () => {
    const village = createVillageProfile({
      id: 'v-a',
      name: 'A',
      accountSnapshot: emptySnapshot('{"tag":"#ABC","buildings":[]}'),
    });
    const result = prepareQuickImport({
      text: '{"tag":"#abc","buildings":[]}',
      targetVillageId: village.id,
      villages: [village],
      clock: new FakeClock(0),
    });
    expect(result.ok).toBe(true);
    if (!result.ok) {
      return;
    }
    expect(result.value.replacesSameTag).toBe(false);
    expect(result.value.destinationDescription).toContain('Tag 变化被重置');
  });

  it('无 tag JSON 允许导入且走缺失分支', () => {
    const village = createVillageProfile({
      id: 'v-a',
      name: 'A',
      accountSnapshot: emptySnapshot('{"tag":"#OLD","buildings":[]}'),
      officialAPIState: { status: 'success' },
    });
    const result = prepareQuickImport({
      text: '{"buildings":[]}',
      targetVillageId: village.id,
      villages: [village],
      clock: new FakeClock(0),
    });
    expect(result.ok).toBe(true);
    if (!result.ok) {
      return;
    }
    expect(result.value.replacesSameTag).toBe(false);
    expect(result.value.destinationDescription).toContain('未提供账号 Tag');
    expect(result.value.destinationDescription).toContain('按当前目标处理');
  });

  it('applySnapshotToVillage 在 tag 缺失时清空 officialAPIState', () => {
    const village = createVillageProfile({
      id: 'v-a',
      name: 'A',
      accountSnapshot: emptySnapshot('{"tag":"#OLD","buildings":[]}'),
      officialAPIState: { status: 'success' },
    });
    const next = applySnapshotToVillage(village, emptySnapshot('{"buildings":[]}'));
    expect(next.officialAPIState).toBeNull();
  });

  it('resolvePendingTarget 在无匹配 tag 且未选中导入当前村庄时创建新村庄', () => {
    const villages = [
      createVillageProfile({ id: 'v-a', name: 'A' }),
      createVillageProfile({ id: 'v-b', name: 'B' }),
    ];
    const snapshot = emptySnapshot('{"tag":"#NEW","buildings":[]}');
    expect(
      resolvePendingTarget(snapshot, villages, {
        selectedVillageId: 'v-a',
        importIntoCurrentVillage: false,
      }),
    ).toEqual({ kind: 'create' });
  });

  it('parsePendingImport 对重复 tag 返回 ambiguous', () => {
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
    const result = parsePendingImport({
      text: '{"tag":"#DUP","buildings":[]}',
      villages,
      selectedVillageId: '1',
      importIntoCurrentVillage: false,
      clock: new FakeClock(0),
    });
    expect(result.ok).toBe(false);
    if (result.ok) {
      return;
    }
    expect(result.error).toMatchObject({ kind: 'ambiguous' });
  });
});
