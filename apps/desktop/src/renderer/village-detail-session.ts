/**
 * Village Detail 会话态（#277-C1）：纯函数，只消费 village.detail DTO。
 * 世代/session 守卫复用 overview-session（cursor 形状与语义一致）。
 */
import type {
  CatalogAssetRefDto,
  CatalogCompatibilityDto,
  CatalogDurationStateDto,
  ProgressMetricDto,
  TrackerBaseDto,
  TrackerCategoryDto,
  TrackerDisplayCategoryDto,
  UpgradeRequirementDto,
  VillageDetailGroupDto,
  VillageDetailPayload,
  VillageItemStateDto,
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

export function requirementLabel(req: UpgradeRequirementDto, base: TrackerBaseDto): string {
  let name: string;
  switch (req.kind) {
    case 'townHall':
      name = base === 'builder' ? '建筑大师大本营' : '大本营';
      break;
    case 'builderHall':
      name = '建筑大师大本营';
      break;
    case 'laboratory':
      name = base === 'builder' ? '星空实验室' : '实验室';
      break;
    case 'starLaboratory':
      name = '星空实验室';
      break;
    case 'heroHall':
      name = '英雄殿堂';
      break;
    case 'blacksmith':
      name = '铁匠铺';
      break;
    default: {
      const exhaustive: never = req;
      throw new Error(`未知升级前置：${String(exhaustive)}`);
    }
  }
  return `所需${name}等级 ${req.level}级`;
}

export function formatDurationSeconds(seconds: number): string {
  if (!(seconds > 0)) {
    return '不足1分钟';
  }
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (days > 0) {
    return `${days}天 ${hours}小时`;
  }
  if (hours > 0) {
    return `${hours}小时 ${minutes}分钟`;
  }
  if (minutes > 0) {
    return `${minutes}分钟`;
  }
  return '不足1分钟';
}

export function durationStateLabel(state: CatalogDurationStateDto | null): string {
  if (state === null) {
    return '暂无目录数据';
  }
  switch (state.kind) {
    case 'timed':
      return formatDurationSeconds(state.seconds);
    case 'instant':
      return '即时';
    case 'initialLevel':
      return '初始等级，无升级时长';
    case 'notApplicable':
      return '该类别无时长数据';
    case 'sourceMissing':
      return '目录缺失';
    case 'parseFailed':
      return '目录解析失败';
    case 'unknownReason':
      return '暂无目录数据';
    default: {
      const exhaustive: never = state;
      throw new Error(`未知时长状态：${String(exhaustive)}`);
    }
  }
}

/** 等级底片图标优先级：当级 icon/visual 优先，通用 icon/visual 兜底。 */
export function primaryLevelAsset(item: VillageItemStateDto): CatalogAssetRefDto | null {
  return item.currentLevelIcon ?? item.currentLevelVisual ?? item.icon ?? item.levelVisual;
}
