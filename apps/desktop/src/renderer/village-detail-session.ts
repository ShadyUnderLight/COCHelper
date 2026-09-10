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
  VillageItemStatusDto,
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
    instanceItems: [],
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

/**
 * 类别 glyph（#39 最终 fallback 用：PNG 候选耗尽时显示分类首字而非消失。
 * Electron 无 SF Symbols，用分类标题首字是稳定可本地化的最小方案）。
 */
export function categoryGlyph(
  displayCategory: TrackerDisplayCategoryDto | null,
  category: TrackerCategoryDto | null,
): string {
  if (displayCategory !== null) {
    return displayCategoryLabel(displayCategory).slice(0, 1);
  }
  if (category !== null) {
    return categoryLabel(category).slice(0, 1);
  }
  return '？';
}

export function levelTransitionText(currentLevel: number | null, nextLevel: number | null): string {
  if (currentLevel !== null) {
    if (nextLevel !== null) {
      return `${currentLevel} → ${nextLevel} 级`;
    }
    return `等级 ${currentLevel} 级`;
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

function stageMaxedText(currentStageMaxLevel: number | null, maxLevel: number | null): string {
  if (currentStageMaxLevel !== null && maxLevel !== null && currentStageMaxLevel < maxLevel) {
    return `当前阶段已满级（全局尚有 ${maxLevel - currentStageMaxLevel} 级）`;
  }
  return '已满级';
}

/**
 * 权威展示状态（复刻 LevelDetailSheet.swift statusLabel）。
 * effective sidecar 存在即权威，绝不把 raw status 与 effective 并列展示。
 * 满级判定直接消费 DTO 的 effectiveIsMaxed（Main 侧 domain 已含 known 门）；
 * 本模块不再做任何满级数值判断。
 */
export function authoritativeLevelStatus(item: VillageItemStateDto): string {
  const effective = item.effectiveStatus;
  if (effective !== null) {
    switch (effective) {
      case 'manualActive':
      case 'importedActive':
        return '正在升级';
      case 'needsReimport':
        return '待重新导入确认';
      case 'conflict':
        return '本地状态冲突';
      case 'unknown':
        return '无法确认当前状态';
      case 'unavailable':
        return '不参与升级追踪';
      case 'manualCompleted':
      case 'observed': {
        if (item.effectiveIsMaxed) {
          return stageMaxedText(item.currentStageMaxLevel, item.maxLevel);
        }
        return '已记录';
      }
      default: {
        const exhaustive: never = effective;
        throw new Error(`未知有效状态：${String(exhaustive)}`);
      }
    }
  }
  if (item.status === 'maxed') {
    return stageMaxedText(item.currentStageMaxLevel, item.maxLevel);
  }
  // NOTE: 下方 case 'maxed' 不可达（上方已 return），仅为穷尽 switch 而保留；
  // 判别式经 as 加宽，否则 narrowing 后 'maxed' 与判别类型不可比（TS2678）。
  const rawWidened = item.status as VillageItemStatusDto;
  switch (rawWidened) {
    case 'upgrading':
      return '正在升级';
    case 'maxed':
      return stageMaxedText(item.currentStageMaxLevel, item.maxLevel);
    case 'complete':
      return '已记录';
    case 'unknown':
      return '目录未收录';
    case 'unverified':
      return '无法验证当前阶段上限';
    case 'unavailable':
      return '不参与升级追踪';
    case 'available':
      return '目录中可用';
    default: {
      const exhaustive: never = rawWidened;
      throw new Error(`未知状态：${String(exhaustive)}`);
    }
  }
}

/** 图标候选链（复刻 preferredAssetURLs 顺序：currentLevelVisual → currentLevelIcon → levelVisual → icon；craftTable 模组图标无 renderer 数据源，不在链内）。空位保留 null，由调用方按序探测。 */
export function primaryLevelAssets(
  item: VillageItemStateDto,
): readonly (CatalogAssetRefDto | null)[] {
  return [item.currentLevelVisual, item.currentLevelIcon, item.levelVisual, item.icon];
}
