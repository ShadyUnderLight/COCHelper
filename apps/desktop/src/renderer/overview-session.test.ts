import { describe, expect, it } from 'vitest';

import type {
  CatalogAvailabilityDto,
  EffectiveVillageItemStatusDto,
  UpgradeOverviewPayload,
  UpgradeOverviewStateDto,
  UpgradeRecentCompletionDto,
  VillageItemStatusDto,
} from '@coc-helper/contracts';

import {
  INITIAL_OVERVIEW_STATE,
  applyOverviewError,
  applyOverviewSuccess,
  availabilityLabel,
  cursorFromOverview,
  effectiveStatusLabel,
  isCatalogUnavailable,
  isEmptyOverview,
  recordFixture,
  shouldAcceptOverview,
  statusLabel,
} from './overview-session';

function payload(overrides: Partial<UpgradeOverviewPayload> = {}): UpgradeOverviewPayload {
  return {
    generation: 7,
    nowMs: 1_700_000_000_000,
    catalogVersion: '18.400.13',
    catalogIsUsable: true,
    active: [],
    pending: [],
    state: {
      manualActiveCount: 0,
      importedActiveCount: 0,
      deduplicatedDisplayCount: 0,
      manualCompletedCount: 0,
      completedRecently: [],
      activeRecords: [],
      attentionRecords: [],
      needsReimportRecords: [],
    },
    ...overrides,
  };
}

function stateWith(overrides: Partial<UpgradeOverviewStateDto> = {}): UpgradeOverviewStateDto {
  return {
    manualActiveCount: 0,
    importedActiveCount: 0,
    deduplicatedDisplayCount: 0,
    manualCompletedCount: 0,
    completedRecently: [],
    activeRecords: [],
    attentionRecords: [],
    needsReimportRecords: [],
    ...overrides,
  };
}

describe('shouldAcceptOverview', () => {
  it('首帧无 cursor 时接受', () => {
    expect(shouldAcceptOverview(null, 's1', 1)).toBe(true);
  });
  it('同 session 仅接受 generation>=', () => {
    expect(shouldAcceptOverview({ sessionId: 's1', generation: 5 }, 's1', 5)).toBe(true);
    expect(shouldAcceptOverview({ sessionId: 's1', generation: 5 }, 's1', 6)).toBe(true);
    expect(shouldAcceptOverview({ sessionId: 's1', generation: 5 }, 's1', 4)).toBe(false);
  });
  it('跨 session 拒绝', () => {
    expect(shouldAcceptOverview({ sessionId: 's1', generation: 5 }, 's2', 9)).toBe(false);
  });
});

describe('applyOverviewSuccess/applyOverviewError', () => {
  it('成功进入 ready 态并清空错误', () => {
    const err = applyOverviewError(INITIAL_OVERVIEW_STATE, 'boom');
    expect(err.status).toBe('error');
    const ok = applyOverviewSuccess(payload());
    expect(ok).toEqual({ status: 'ready', payload: payload(), lastError: null });
  });
  it('无 last-good 时错误进 error 态', () => {
    const next = applyOverviewError(INITIAL_OVERVIEW_STATE, 'boom');
    expect(next).toEqual({ status: 'error', payload: null, lastError: 'boom' });
  });
  it('有 last-good 时错误保持 ready 并挂 lastError（failed-with-last-good）', () => {
    const good = applyOverviewSuccess(payload());
    const next = applyOverviewError(good, 'stale-fail');
    expect(next.status).toBe('ready');
    expect(next.payload).toBe(good.payload);
    expect(next.lastError).toBe('stale-fail');
  });
});

describe('cursorFromOverview/isEmptyOverview', () => {
  it('cursor 取 payload generation', () => {
    expect(cursorFromOverview('s1', payload({ generation: 9 }))).toEqual({
      sessionId: 's1',
      generation: 9,
    });
  });
  it('全空才算 empty', () => {
    expect(isEmptyOverview(payload())).toBe(true);
    expect(isEmptyOverview(payload({ active: [recordFixture()] }))).toBe(false);
  });
});

describe('label 表格（I2）', () => {
  it('statusLabel 覆盖全部 VillageItemStatusDto', () => {
    const table: Array<[VillageItemStatusDto, string]> = [
      ['upgrading', '进行中'],
      ['complete', '已完成'],
      ['maxed', '已满级'],
      ['unknown', '未知'],
      ['unavailable', '不可用'],
      ['available', '可升级'],
      ['unverified', '未验证'],
    ];
    for (const [status, expected] of table) {
      expect(statusLabel(status)).toBe(expected);
    }
  });
  it('effectiveStatusLabel 覆盖全部 EffectiveVillageItemStatusDto + null', () => {
    const table: Array<[EffectiveVillageItemStatusDto | null, string | null]> = [
      [null, null],
      ['observed', '已同步'],
      ['manualCompleted', '手动已完成'],
      ['manualActive', '手动进行中'],
      ['importedActive', '导入进行中'],
      ['needsReimport', '待重新导入'],
      ['conflict', '冲突'],
      ['unknown', '未知'],
      ['unavailable', '不可用'],
    ];
    for (const [status, expected] of table) {
      expect(effectiveStatusLabel(status)).toBe(expected);
    }
  });
  it('availabilityLabel 覆盖全部 CatalogAvailabilityDto', () => {
    const table: Array<[CatalogAvailabilityDto, string | null]> = [
      [{ kind: 'permanent' }, null],
      [{ kind: 'seasonal', phaseID: 'p1', phaseName: '新春', status: 'active' }, '限时：新春'],
      [{ kind: 'seasonal', phaseID: 'p1', phaseName: null, status: 'ended' }, '限时：p1'],
      [{ kind: 'unconfigured' }, '目录未配置'],
      [
        { kind: 'conflict', phaseID: 'p2', phaseName: null, lifecycle: 'x', sourceURL: null },
        '声明冲突：p2',
      ],
    ];
    for (const [availability, expected] of table) {
      expect(availabilityLabel(availability)).toBe(expected);
    }
  });
  it('isCatalogUnavailable', () => {
    expect(isCatalogUnavailable(payload({ catalogIsUsable: false }))).toBe(true);
    expect(isCatalogUnavailable(payload({ catalogIsUsable: true }))).toBe(false);
  });
});

describe('isEmptyOverview 参数化（I3）', () => {
  it('任一列表非空即非 empty', () => {
    const completion: UpgradeRecentCompletionDto = {
      id: 'c1',
      villageID: 'v1',
      itemKey: {
        base: 'home',
        rawSection: 'buildings',
        dataID: 1,
        nestedKind: 'none',
        nestedRootIdentity: null,
        nestedPath: [],
        stableId: 's',
      },
      itemName: 'x',
      targetLevel: 2,
      quantity: 1,
      completedAtMs: 1,
    };
    const cases: Array<[string, UpgradeOverviewPayload]> = [
      ['active', payload({ active: [recordFixture()] })],
      ['pending', payload({ pending: [recordFixture()] })],
      ['state.activeRecords', payload({ state: stateWith({ activeRecords: [recordFixture()] }) })],
      [
        'state.attentionRecords',
        payload({ state: stateWith({ attentionRecords: [recordFixture()] }) }),
      ],
      [
        'state.needsReimportRecords',
        payload({ state: stateWith({ needsReimportRecords: [recordFixture()] }) }),
      ],
      [
        'state.completedRecently',
        payload({ state: stateWith({ completedRecently: [completion] }) }),
      ],
    ];
    expect(isEmptyOverview(payload())).toBe(true);
    for (const [name, p] of cases) {
      expect(isEmptyOverview(p), name).toBe(false);
    }
  });
});
