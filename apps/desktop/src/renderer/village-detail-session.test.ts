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
  authoritativeLevelStatus,
  categoryGlyph,
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
  levelMissingNote,
  levelTransitionText,
  metricStateLabel,
  primaryLevelAssets,
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
  it('仅当前级', () => {
    expect(levelTransitionText(5, null)).toBe('等级 5 级');
  });
  it('等级未知', () => {
    expect(levelTransitionText(null, null)).toBe('等级未知');
  });
});

describe('categoryGlyph', () => {
  it('展示分类优先：防御建筑→防 / 城墙→城', () => {
    expect(categoryGlyph('defense', 'buildings')).toBe('防');
    expect(categoryGlyph('walls', 'buildings')).toBe('城');
    expect(categoryGlyph('military', 'buildings')).toBe('军');
    expect(categoryGlyph('craftTable', 'buildings')).toBe('精');
  });
  it('无展示分类时用原分类首字', () => {
    expect(categoryGlyph(null, 'traps')).toBe('陷');
    expect(categoryGlyph(null, 'heroes')).toBe('英');
  });
  it('双空 → ？', () => {
    expect(categoryGlyph(null, null)).toBe('？');
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

describe('primaryLevelAssets（#277-C2）', () => {
  it('顺序 currentLevelVisual → currentLevelIcon → levelVisual → icon，空位保留 null', () => {
    const base = recordFixture().item;
    const curVisual = {
      container: 'sc',
      exportName: 'a',
      renderedPath: 'icons/a.png',
      missingReason: null,
    } as const;
    const curIcon = {
      container: 'sc',
      exportName: 'b',
      renderedPath: 'icons/b.png',
      missingReason: null,
    } as const;
    const visual = {
      container: 'sc',
      exportName: 'c',
      renderedPath: 'icons/c.png',
      missingReason: null,
    } as const;
    const icon = {
      container: 'sc',
      exportName: 'd',
      renderedPath: 'icons/d.png',
      missingReason: null,
    } as const;
    expect(
      primaryLevelAssets({
        ...base,
        currentLevelVisual: curVisual,
        currentLevelIcon: curIcon,
        levelVisual: visual,
        icon,
      }),
    ).toEqual([curVisual, curIcon, visual, icon]);
    expect(
      primaryLevelAssets({
        ...base,
        currentLevelVisual: null,
        currentLevelIcon: curIcon,
        levelVisual: null,
        icon,
      }),
    ).toEqual([null, curIcon, null, icon]);
    expect(
      primaryLevelAssets({
        ...base,
        currentLevelVisual: null,
        currentLevelIcon: null,
        levelVisual: null,
        icon: null,
      }),
    ).toEqual([null, null, null, null]);
  });
});

describe('authoritativeLevelStatus（#277-C2 review）', () => {
  it('upgrading + manualCompleted → 已记录（绝非进行中）', () => {
    const item = {
      ...recordFixture().item,
      status: 'upgrading' as const,
      effectiveStatus: 'manualCompleted' as const,
    };
    expect(authoritativeLevelStatus(item)).toBe('已记录');
  });
  it('upgrading + observed → 已记录', () => {
    const item = {
      ...recordFixture().item,
      status: 'upgrading' as const,
      effectiveStatus: 'observed' as const,
    };
    expect(authoritativeLevelStatus(item)).toBe('已记录');
  });
  it('upgrading + manualActive → 正在升级', () => {
    const item = {
      ...recordFixture().item,
      status: 'upgrading' as const,
      effectiveStatus: 'manualActive' as const,
    };
    expect(authoritativeLevelStatus(item)).toBe('正在升级');
  });
  it('conflict → 本地状态冲突', () => {
    const item = { ...recordFixture().item, effectiveStatus: 'conflict' as const };
    expect(authoritativeLevelStatus(item)).toBe('本地状态冲突');
  });
  it('needsReimport → 待重新导入确认', () => {
    const item = { ...recordFixture().item, effectiveStatus: 'needsReimport' as const };
    expect(authoritativeLevelStatus(item)).toBe('待重新导入确认');
  });
  it('unavailable → 不参与升级追踪', () => {
    const item = { ...recordFixture().item, effectiveStatus: 'unavailable' as const };
    expect(authoritativeLevelStatus(item)).toBe('不参与升级追踪');
  });
  it('null + maxed → 已满级', () => {
    const item = { ...recordFixture().item, status: 'maxed' as const, effectiveStatus: null };
    expect(authoritativeLevelStatus(item)).toBe('已满级');
  });
  it('null + unknown → 目录未收录', () => {
    const item = { ...recordFixture().item, status: 'unknown' as const, effectiveStatus: null };
    expect(authoritativeLevelStatus(item)).toBe('目录未收录');
  });
  it('manualCompleted + effectiveIsMaxed → 已满级/阶段文案', () => {
    const maxed = {
      ...recordFixture().item,
      status: 'upgrading' as const,
      effectiveStatus: 'manualCompleted' as const,
      effectiveIsMaxed: true,
      currentStageMaxLevel: 10,
      maxLevel: 10,
    };
    expect(authoritativeLevelStatus(maxed)).toBe('已满级');
    const stageMaxed = {
      ...recordFixture().item,
      status: 'upgrading' as const,
      effectiveStatus: 'manualCompleted' as const,
      effectiveIsMaxed: true,
      currentStageMaxLevel: 8,
      maxLevel: 10,
    };
    expect(authoritativeLevelStatus(stageMaxed)).toBe('当前阶段已满级（全局尚有 2 级）');
  });
  it('observed + effectiveIsMaxed=false（未知分布）→ 已记录，不误报满级', () => {
    const item = {
      ...recordFixture().item,
      status: 'upgrading' as const,
      effectiveStatus: 'observed' as const,
      currentLevel: 10,
      effectiveCurrentLevel: 10,
      currentStageMaxLevel: 10,
      maxLevel: 10,
      effectiveIsMaxed: false,
    };
    expect(authoritativeLevelStatus(item)).toBe('已记录');
  });
});

describe('levelMissingNote（#277-C2 review）', () => {
  it('isNested → 内部子项目说明', () => {
    const item = { ...recordFixture().item, isNested: true };
    expect(levelMissingNote(item)).toBe('该项目属于内部子项目，暂不提供逐级升级数据。');
  });
  it('conflict → 冲突说明', () => {
    const item = { ...recordFixture().item, isNested: false, effectiveStatus: 'conflict' as const };
    expect(levelMissingNote(item)).toBe('本地手动状态冲突，暂无法确认当前等级。');
  });
  it('deprecated 优先于 effective obs → 废弃说明', () => {
    const item = {
      ...recordFixture().item,
      isNested: false,
      catalogItemMissingReason: 'deprecated_in_source',
      effectiveStatus: 'conflict' as const,
    };
    expect(levelMissingNote(item)).toBe(
      '该条目在源目录中标记为已废弃（仅作历史数据展示，不参与当前内容）。',
    );
  });
  it('conflict + effectiveDiagnostic → 透出诊断', () => {
    const diagnosed = {
      ...recordFixture().item,
      isNested: false,
      effectiveStatus: 'conflict' as const,
      effectiveDiagnostic: '手动记录目录版本与当前目录不一致',
    };
    expect(levelMissingNote(diagnosed)).toBe('手动记录目录版本与当前目录不一致');
  });
  it('needsReimport → 重导说明', () => {
    const item = {
      ...recordFixture().item,
      isNested: false,
      effectiveStatus: 'needsReimport' as const,
    };
    expect(levelMissingNote(item)).toBe('导入计时已结束，重新导入快照后才能确认当前等级。');
  });
  it('unknown-effective（raw 非 unknown/unverified）→ 未知说明', () => {
    const item = {
      ...recordFixture().item,
      isNested: false,
      status: 'upgrading' as const,
      effectiveStatus: 'unknown' as const,
    };
    expect(levelMissingNote(item)).toBe('本地有效状态未知，暂无法确认当前等级。');
  });
  it('raw unverified 透出 missingReason', () => {
    const item = {
      ...recordFixture().item,
      isNested: false,
      status: 'unverified' as const,
      effectiveStatus: null,
      missingReason: '缺解锁建筑',
    };
    expect(levelMissingNote(item)).toBe('缺解锁建筑');
  });
  it('raw unknown 默认文案', () => {
    const item = {
      ...recordFixture().item,
      isNested: false,
      status: 'unknown' as const,
      effectiveStatus: null,
      missingReason: null,
    };
    expect(levelMissingNote(item)).toBe('该项目暂无逐级升级数据。');
  });
  it('available 条目 → null', () => {
    const item = {
      ...recordFixture().item,
      isNested: false,
      status: 'available' as const,
      effectiveStatus: null,
      missingReason: null,
    };
    expect(levelMissingNote(item)).toBeNull();
  });
});
