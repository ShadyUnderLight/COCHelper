/**
 * Village Detail 会话态（#277-C1）：纯函数，只消费 village.detail DTO。
 * 世代/session 守卫复用 overview-session（cursor 形状与语义一致）。
 */
import type {
  CatalogCompatibilityDto,
  ProgressMetricDto,
  TrackerCategoryDto,
  TrackerDisplayCategoryDto,
  VillageDetailGroupDto,
  VillageDetailPayload,
} from '@coc-helper/contracts';

export type VillageDetailState = {
  readonly status: 'loading' | 'ready' | 'error' | 'idle';
  readonly payload: VillageDetailPayload | null;
  readonly lastError: string | null;
};

export const INITIAL_VILLAGE_DETAIL_STATE: VillageDetailState = {
  status: 'loading',
  payload: null,
  lastError: null,
};

export function idleVillageDetailState(): VillageDetailState {
  return { status: 'idle', payload: null, lastError: null };
}

export function applyVillageDetailSuccess(payload: VillageDetailPayload): VillageDetailState {
  return { status: 'ready', payload, lastError: null };
}

export function applyVillageDetailError(
  prev: VillageDetailState,
  message: string,
): VillageDetailState {
  if (prev.payload === null) {
    return { status: 'error', payload: null, lastError: message };
  }
  return { status: 'ready', payload: prev.payload, lastError: message };
}

export function isEmptyDetail(payload: VillageDetailPayload): boolean {
  return payload.flatRows.length === 0;
}

export function metricStateLabel(state: ProgressMetricDto['state']): string {
  switch (state) {
    case 'ready':
      return '就绪';
    case 'partial':
      return '部分';
    case 'unavailable':
      return '不可用';
    case 'unknown':
      return '未知';
    default: {
      const exhaustive: never = state;
      throw new Error(`未知指标状态：${String(exhaustive)}`);
    }
  }
}

export function compatibilityAlertText(compatibility: CatalogCompatibilityDto): string | null {
  switch (compatibility.kind) {
    case 'mismatch':
      return `目录版本不一致：${compatibility.catalogVersion}（期望 ${compatibility.expectedVersion}）`;
    case 'unavailable':
      return '游戏目录不可用，详情数据可能不完整';
    case 'unverified':
    case 'verified':
      return null;
    default: {
      const exhaustive: never = compatibility;
      throw new Error(`未知目录兼容状态：${String(exhaustive)}`);
    }
  }
}

export function compatibilityVersionText(compatibility: CatalogCompatibilityDto): string | null {
  switch (compatibility.kind) {
    case 'unverified':
      return `${compatibility.gameVersion} · 未验证`;
    case 'verified':
      return compatibility.gameVersion;
    case 'mismatch':
      return compatibility.catalogVersion;
    case 'unavailable':
      return null;
    default: {
      const exhaustive: never = compatibility;
      throw new Error(`未知目录兼容状态：${String(exhaustive)}`);
    }
  }
}

export function formatCompletionPercent(ratio: number | null): string | null {
  if (ratio === null || !Number.isFinite(ratio)) {
    return null;
  }
  return `${Math.round(ratio * 100)}%`;
}

/** 测试与组件共用的最小 payload fixture（字段按 contracts/projection-ipc.ts 全量给出）。 */
export function villageDetailFixture(
  overrides: Partial<VillageDetailPayload> = {},
): VillageDetailPayload {
  const metric = {
    kind: 'test',
    numerator: 1,
    denominator: 2,
    state: 'ready' as const,
    saturated: false,
    units: 'items',
    degradedReason: null,
    ratio: 0.5,
  };
  return {
    generation: 1,
    nowMs: 1,
    villageId: 'v1',
    villageName: '主村',
    villageTag: '#AAA',
    base: 'home',
    catalogVersion: '18.400.13',
    catalogIsUsable: true,
    compatibility: { kind: 'verified', gameVersion: '18.400.13' },
    items: [],
    groups: [],
    completion: [],
    totalCompletion: {
      id: 'total',
      category: null,
      displayCategory: null,
      knownCount: 0,
      completedCount: 0,
      unknownCount: 0,
      saturated: false,
      completionRatio: null,
      isFullyMaxed: false,
    },
    metrics: {
      currentStageProgress: metric,
      globalProgress: metric,
      snapshotCoverage: metric,
      instanceProgress: metric,
      effectiveTrackerProgress: metric,
    },
    buildingGroups: [],
    flatRows: [],
    ...overrides,
  };
}

export function categoryLabel(category: TrackerCategoryDto): string {
  switch (category) {
    case 'buildings':
      return '建筑与防御';
    case 'traps':
      return '陷阱';
    case 'troops':
      return '兵种';
    case 'spells':
      return '法术';
    case 'siegeMachines':
      return '攻城机器';
    case 'heroes':
      return '英雄';
    case 'equipment':
      return '装备';
    case 'pets':
      return '战宠';
    case 'guardians':
      return '守卫';
    default: {
      const exhaustive: never = category;
      throw new Error(`未知分类：${String(exhaustive)}`);
    }
  }
}

export function displayCategoryLabel(display: TrackerDisplayCategoryDto): string {
  switch (display) {
    case 'defense':
      return '防御建筑';
    case 'walls':
      return '城墙';
    case 'military':
      return '军事设施';
    case 'craftTable':
      return '精制台';
    default: {
      const exhaustive: never = display;
      throw new Error(`未知展示分类：${String(exhaustive)}`);
    }
  }
}

export function levelTransitionText(currentLevel: number | null, nextLevel: number | null): string {
  if (currentLevel !== null && nextLevel !== null) {
    return `${currentLevel} → ${nextLevel} 级`;
  }
  if (nextLevel !== null) {
    return `下一级 ${nextLevel} 级`;
  }
  return '等级未知';
}

export function groupTitleText(group: VillageDetailGroupDto): string {
  if (group.displayCategory !== null) {
    return displayCategoryLabel(group.displayCategory);
  }
  if (group.category !== null) {
    return categoryLabel(group.category);
  }
  return group.id;
}
