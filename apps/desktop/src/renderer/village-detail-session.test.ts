import { describe, expect, it } from 'vitest';

import type {
  CatalogCompatibilityDto,
  CatalogDurationStateDto,
  ProgressMetricDto,
  TrackerCategoryDto,
  TrackerDisplayCategoryDto,
  UpgradeRequirementDto,
} from '@coc-helper/contracts';

import { recordFixture } from './overview-session';
import {
  INITIAL_VILLAGE_DETAIL_STATE,
  applyVillageDetailError,
  applyVillageDetailSuccess,
  categoryLabel,
  compatibilityAlertText,
  compatibilityVersionText,
  displayCategoryLabel,
  durationStateLabel,
  formatCompletionPercent,
  formatDurationSeconds,
  groupTitleText,
  idleVillageDetailState,
  isEmptyDetail,
  levelTransitionText,
  metricStateLabel,
  primaryLevelAsset,
  requirementLabel,
  villageDetailFixture,
} from './village-detail-session';

describe('applyVillageDetailSuccess/applyVillageDetailError', () => {
  it('成功进入 ready 态并清空错误', () => {
    const err = applyVillageDetailError(INITIAL_VILLAGE_DETAIL_STATE, 'boom');
    expect(err.status).toBe('error');
    const ok = applyVillageDetailSuccess(villageDetailFixture());
    expect(ok).toEqual({
      status: 'ready',
      payload: villageDetailFixture(),
      lastError: null,
    });
  });
  it('无 last-good 时错误进 error 态', () => {
    const next = applyVillageDetailError(INITIAL_VILLAGE_DETAIL_STATE, 'boom');
    expect(next).toEqual({ status: 'error', payload: null, lastError: 'boom' });
  });
  it('有 last-good 时错误保持 ready 并挂 lastError（failed-with-last-good）', () => {
    const good = applyVillageDetailSuccess(villageDetailFixture());
    const next = applyVillageDetailError(good, 'stale-fail');
    expect(next.status).toBe('ready');
    expect(next.payload).toBe(good.payload);
    expect(next.lastError).toBe('stale-fail');
  });
});

describe('idleVillageDetailState', () => {
  it('idle 形状', () => {
    expect(idleVillageDetailState()).toEqual({ status: 'idle', payload: null, lastError: null });
  });
});

describe('isEmptyDetail', () => {
  it('flatRows 为空即 empty', () => {
    expect(isEmptyDetail(villageDetailFixture())).toBe(true);
  });
  it('flatRows 非空即非 empty', () => {
    expect(
      isEmptyDetail(villageDetailFixture({ flatRows: [{ kind: 'groupHeader', groupID: 'g' }] })),
    ).toBe(false);
  });
});

describe('metricStateLabel', () => {
  it('覆盖全部 ProgressMetricDto state', () => {
    const table: Array<[ProgressMetricDto['state'], string]> = [
      ['ready', '就绪'],
      ['partial', '部分'],
      ['unavailable', '不可用'],
      ['unknown', '未知'],
    ];
    for (const [state, expected] of table) {
      expect(metricStateLabel(state)).toBe(expected);
    }
  });
});

describe('compatibilityAlertText', () => {
  it('覆盖全部 CatalogCompatibilityDto', () => {
    const table: Array<[CatalogCompatibilityDto, string | null]> = [
      [{ kind: 'verified', gameVersion: '18.400.13' }, null],
      [{ kind: 'unverified', gameVersion: '18.400.13' }, null],
      [
        { kind: 'mismatch', catalogVersion: '18.400.12', expectedVersion: '18.400.13' },
        '目录版本不一致：18.400.12（期望 18.400.13）',
      ],
      [{ kind: 'unavailable' }, '游戏目录不可用，详情数据可能不完整'],
    ];
    for (const [compatibility, expected] of table) {
      expect(compatibilityAlertText(compatibility)).toBe(expected);
    }
  });
});

describe('compatibilityVersionText', () => {
  it('覆盖全部 CatalogCompatibilityDto', () => {
    const table: Array<[CatalogCompatibilityDto, string | null]> = [
      [{ kind: 'verified', gameVersion: '18.400.13' }, '18.400.13'],
      [{ kind: 'unverified', gameVersion: '18.400.13' }, '18.400.13 · 未验证'],
      [
        { kind: 'mismatch', catalogVersion: '18.400.12', expectedVersion: '18.400.13' },
        '18.400.12',
      ],
      [{ kind: 'unavailable' }, null],
    ];
    for (const [compatibility, expected] of table) {
      expect(compatibilityVersionText(compatibility)).toBe(expected);
    }
  });
});

describe('formatCompletionPercent', () => {
  it('0.5→50%', () => {
    expect(formatCompletionPercent(0.5)).toBe('50%');
  });
  it('0→0%', () => {
    expect(formatCompletionPercent(0)).toBe('0%');
  });
  it('null→null', () => {
    expect(formatCompletionPercent(null)).toBeNull();
  });
  it('NaN→null', () => {
    expect(formatCompletionPercent(NaN)).toBeNull();
  });
});

describe('categoryLabel', () => {
  it('覆盖全部 TrackerCategoryDto', () => {
    const table: Array<[TrackerCategoryDto, string]> = [
      ['buildings', '建筑与防御'],
      ['traps', '陷阱'],
      ['troops', '兵种'],
      ['spells', '法术'],
      ['siegeMachines', '攻城机器'],
      ['heroes', '英雄'],
      ['equipment', '装备'],
      ['pets', '战宠'],
      ['guardians', '守卫'],
    ];
    for (const [category, expected] of table) {
      expect(categoryLabel(category)).toBe(expected);
    }
  });
});

describe('displayCategoryLabel', () => {
  it('覆盖全部 TrackerDisplayCategoryDto', () => {
    const table: Array<[TrackerDisplayCategoryDto, string]> = [
      ['defense', '防御建筑'],
      ['walls', '城墙'],
      ['military', '军事设施'],
      ['craftTable', '精制台'],
    ];
    for (const [display, expected] of table) {
      expect(displayCategoryLabel(display)).toBe(expected);
    }
  });
});

describe('levelTransitionText', () => {
  it('当前级+下一级', () => {
    expect(levelTransitionText(5, 6)).toBe('5 → 6 级');
  });
  it('仅下一级', () => {
    expect(levelTransitionText(null, 6)).toBe('下一级 6 级');
  });
  it('等级未知', () => {
    expect(levelTransitionText(null, null)).toBe('等级未知');
  });
});

describe('groupTitleText', () => {
  it('displayCategory 优先', () => {
    expect(
      groupTitleText({
        id: 'g-def',
        category: 'buildings',
        displayCategory: 'defense',
        itemIds: [],
      }),
    ).toBe('防御建筑');
  });
  it('category 兜底', () => {
    expect(
      groupTitleText({ id: 'g-trap', category: 'traps', displayCategory: null, itemIds: [] }),
    ).toBe('陷阱');
  });
  it('id 兜底', () => {
    expect(
      groupTitleText({ id: 'g-misc', category: null, displayCategory: null, itemIds: [] }),
    ).toBe('g-misc');
  });
});

describe('requirementLabel（#277-C2）', () => {
  it('townHall 按 base 区分名称', () => {
    const home: UpgradeRequirementDto = { kind: 'townHall', level: 10 };
    const builder: UpgradeRequirementDto = { kind: 'townHall', level: 10 };
    expect(requirementLabel(home, 'home')).toBe('所需大本营等级 10级');
    expect(requirementLabel(builder, 'builder')).toBe('所需建筑大师大本营等级 10级');
  });
  it('其余 5 种名称固定', () => {
    const table: Array<[UpgradeRequirementDto, string]> = [
      [{ kind: 'builderHall', level: 5 }, '所需建筑大师大本营等级 5级'],
      [{ kind: 'laboratory', level: 8 }, '所需实验室等级 8级'],
      [{ kind: 'starLaboratory', level: 8 }, '所需星空实验室等级 8级'],
      [{ kind: 'heroHall', level: 3 }, '所需英雄殿堂等级 3级'],
      [{ kind: 'blacksmith', level: 2 }, '所需铁匠铺等级 2级'],
    ];
    for (const [req, expected] of table) {
      expect(requirementLabel(req, 'home')).toBe(expected);
    }
  });
  it('laboratory 按 base 区分名称', () => {
    expect(requirementLabel({ kind: 'laboratory', level: 8 }, 'builder')).toBe(
      '所需星空实验室等级 8级',
    );
  });
  it('join 示例：home 大本营 + 实验室', () => {
    const reqs: readonly UpgradeRequirementDto[] = [
      { kind: 'townHall', level: 10 },
      { kind: 'laboratory', level: 8 },
    ];
    expect(reqs.map((req) => requirementLabel(req, 'home')).join(' · ')).toBe(
      '所需大本营等级 10级 · 所需实验室等级 8级',
    );
  });
});

describe('formatDurationSeconds（#277-C2）', () => {
  it('天/小时/分钟/不足1分钟', () => {
    expect(formatDurationSeconds(90061)).toBe('1天 1小时');
    expect(formatDurationSeconds(3661)).toBe('1小时 1分钟');
    expect(formatDurationSeconds(61)).toBe('1分钟');
    expect(formatDurationSeconds(30)).toBe('不足1分钟');
    expect(formatDurationSeconds(0)).toBe('不足1分钟');
  });
});

describe('durationStateLabel（#277-C2）', () => {
  it('null + 7 kinds', () => {
    const table: Array<[CatalogDurationStateDto | null, string]> = [
      [null, '暂无目录数据'],
      [{ kind: 'timed', seconds: 90061 }, '1天 1小时'],
      [{ kind: 'instant' }, '即时'],
      [{ kind: 'initialLevel' }, '初始等级，无升级时长'],
      [{ kind: 'notApplicable' }, '该类别无时长数据'],
      [{ kind: 'sourceMissing' }, '目录缺失'],
      [{ kind: 'parseFailed' }, '目录解析失败'],
      [{ kind: 'unknownReason', reason: 'x' }, '暂无目录数据'],
    ];
    for (const [state, expected] of table) {
      expect(durationStateLabel(state)).toBe(expected);
    }
  });
});

describe('primaryLevelAsset（#277-C2）', () => {
  it('当级 icon/visual 优先，通用 icon/visual 兜底，全空 → null', () => {
    const base = recordFixture().item;
    const curIcon = {
      container: 'sc',
      exportName: 'a',
      renderedPath: 'icons/a.png',
      missingReason: null,
    } as const;
    const curVisual = {
      container: 'sc',
      exportName: 'b',
      renderedPath: 'icons/b.png',
      missingReason: null,
    } as const;
    const icon = {
      container: 'sc',
      exportName: 'c',
      renderedPath: 'icons/c.png',
      missingReason: null,
    } as const;
    const visual = {
      container: 'sc',
      exportName: 'd',
      renderedPath: 'icons/d.png',
      missingReason: null,
    } as const;
    expect(
      primaryLevelAsset({
        ...base,
        currentLevelIcon: curIcon,
        currentLevelVisual: curVisual,
        icon,
        levelVisual: visual,
      }),
    ).toBe(curIcon);
    expect(
      primaryLevelAsset({
        ...base,
        currentLevelIcon: null,
        currentLevelVisual: curVisual,
        icon,
        levelVisual: visual,
      }),
    ).toBe(curVisual);
    expect(
      primaryLevelAsset({
        ...base,
        currentLevelIcon: null,
        currentLevelVisual: null,
        icon,
        levelVisual: visual,
      }),
    ).toBe(icon);
    expect(
      primaryLevelAsset({
        ...base,
        currentLevelIcon: null,
        currentLevelVisual: null,
        icon: null,
        levelVisual: visual,
      }),
    ).toBe(visual);
    expect(
      primaryLevelAsset({
        ...base,
        currentLevelIcon: null,
        currentLevelVisual: null,
        icon: null,
        levelVisual: null,
      }),
    ).toBeNull();
  });
});
